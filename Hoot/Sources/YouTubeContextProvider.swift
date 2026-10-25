//
//  YouTubeContextProvider.swift
//  Hoot
//
//  Knows what YouTube video the user is watching in the frontmost browser
//  (Google Chrome, Arc, Brave, Edge or Safari), where they are in it, and what
//  was said in the ninety seconds before that point. Pauses the video while the
//  user asks a question and resumes it afterwards, but only if it was playing
//  when we paused it. When the question asks to find a moment ("go back to
//  where she explained X"), hands the tutor the whole transcript and can jump
//  the video to the `[SEEK:mm:ss]` the tutor answers with.
//
//  Browser access goes through AppleScript (NSAppleScript). Every script runs on
//  a background queue and gives up after about a second, so push-to-talk never
//  waits on a slow or unresponsive browser.
//
//  One-time setup the user has to do (we surface these as actionable messages):
//   - Chrome/Brave/Edge: View → Developer → Allow JavaScript from Apple Events
//   - Safari: Develop → Allow JavaScript from Apple Events
//   - macOS asks once per browser: "<this app> wants access to control <browser>"
//

import AppKit
import Combine
import Foundation

// MARK: - Public data types

/// Everything the tutor needs to know about the video the user is watching.
struct YouTubeLearningContext {
    let videoId: String
    let title: String
    let currentTimeSeconds: Double
    /// The transcript lines from roughly ninety seconds before `currentTimeSeconds`
    /// up to it, one per line, each prefixed with a `[mm:ss]` stamp. Nil when the
    /// video has no English transcript or the worker could not be reached.
    let transcriptWindowText: String?
    /// The whole transcript (capped around the current time, with a "you are
    /// here" marker), only when the question asks to find a moment in the
    /// video ("go back to where she explained X"), so the tutor can answer
    /// with a `[SEEK:mm:ss]` tag. Nil otherwise: it is big, and most
    /// questions are about what was just said.
    let fullTranscriptForSeekingText: String?

    /// The text block to append to the user prompt sent to the tutor.
    var promptContextBlock: String {
        let formattedCurrentTime = YouTubeContextProvider.formatTimestampForTranscript(currentTimeSeconds)
        var promptContextLines = [
            "the user is watching the YouTube video \"\(title)\" (video id \(videoId)) and paused it at \(formattedCurrentTime)."
        ]
        if let transcriptWindowText, !transcriptWindowText.isEmpty {
            promptContextLines.append("here's what was said in the last ninety seconds before they paused (the last lines are what the speaker just said):")
            promptContextLines.append(transcriptWindowText)
        }
        if let fullTranscriptForSeekingText, !fullTranscriptForSeekingText.isEmpty {
            promptContextLines.append("")
            promptContextLines.append("they may be asking you to find a moment in the video (to rewind, replay or skip to where something is explained), so here is the whole transcript with timestamps; the \"you are here\" line marks where they paused. if that's what they want: find the line where the thing they mean is first actually explained, not merely mentioned, and end your reply with [SEEK:mm:ss] using that line's stamp, as described under \"rewinding the video\". if they're asking an ordinary question instead, answer it the usual way and don't seek.")
            promptContextLines.append(fullTranscriptForSeekingText)
        } else {
            promptContextLines.append("no transcript is available for this video, so rely on the screenshot.")
        }
        return promptContextLines.joined(separator: "\n")
    }
}

/// The state of the YouTube player in the frontmost browser tab at one moment.
struct YouTubeVideoPlaybackSnapshot {
    let browser: YouTubeSupportedBrowser
    let pageURLString: String
    let videoId: String
    let title: String
    let currentTimeSeconds: Double
    /// Whether the video was already paused before we touched it.
    let wasPausedBeforeWeActed: Bool
}

/// One caption line from the worker's `/youtube/:videoId/transcript` route.
struct YouTubeTranscriptSegment: Decodable {
    let start: Double
    let duration: Double
    let text: String
}

/// Browsers we know how to script. Chromium-based browsers share Chrome's
/// AppleScript dictionary (`execute javascript`); Safari uses `do JavaScript`.
enum YouTubeSupportedBrowser {
    case chromiumBased(bundleIdentifier: String, displayName: String)
    case safari

    static func browserForBundleIdentifier(_ bundleIdentifier: String) -> YouTubeSupportedBrowser? {
        switch bundleIdentifier {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary":
            return .chromiumBased(bundleIdentifier: bundleIdentifier, displayName: "Google Chrome")
        case "company.thebrowser.Browser":
            return .chromiumBased(bundleIdentifier: bundleIdentifier, displayName: "Arc")
        case "com.brave.Browser":
            return .chromiumBased(bundleIdentifier: bundleIdentifier, displayName: "Brave")
        case "com.microsoft.edgemac":
            return .chromiumBased(bundleIdentifier: bundleIdentifier, displayName: "Microsoft Edge")
        case "com.apple.Safari":
            return .safari
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .chromiumBased(_, let displayName): return displayName
        case .safari: return "Safari"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chromiumBased(let bundleIdentifier, _): return bundleIdentifier
        case .safari: return "com.apple.Safari"
        }
    }

    /// Where the user turns on "Allow JavaScript from Apple Events" in this browser.
    var allowJavaScriptFromAppleEventsInstructions: String {
        switch self {
        case .chromiumBased(_, let displayName):
            if displayName == "Arc" {
                return "Arc blocked JavaScript from Apple Events. Check Arc's settings for an \"Allow JavaScript from Apple Events\" option, or watch the video in Google Chrome."
            }
            return "To let me see where you are in YouTube videos, turn on \(displayName) → View → Developer → Allow JavaScript from Apple Events (one time)."
        case .safari:
            return "To let me see where you are in YouTube videos, turn on Safari → Develop → Allow JavaScript from Apple Events (enable the Develop menu in Safari Settings → Advanced first)."
        }
    }
}

// MARK: - Provider

@MainActor
final class YouTubeContextProvider: ObservableObject {

    /// A human-readable, actionable message when the browser blocked us (for example
    /// "Allow JavaScript from Apple Events" is off, or the Automation permission was
    /// denied). Nil when the last browser query worked. The UI can show this.
    @Published private(set) var browserSetupProblemMessage: String?

    /// The snapshot captured by the most recent `pauseVideo()` call. Used to build
    /// the learning context once the user's question has been transcribed.
    private(set) var mostRecentPausedVideoSnapshot: YouTubeVideoPlaybackSnapshot?

    /// True only when the video was playing and we paused it, so
    /// `resumeVideoIfWePausedIt()` never starts a video the user had paused themselves.
    private var didWePauseTheMostRecentVideo = false

    /// How many seconds of transcript before the current time to give the tutor.
    private let transcriptWindowLengthSeconds: Double = 90

    /// The most transcript text handed over for a seek question, in characters
    /// (roughly 9k tokens, about forty minutes of lecture). Longer videos get
    /// the part nearest the current time, weighted toward what was already
    /// watched, because "go back to" is far more common than "skip ahead to".
    private let fullTranscriptCharacterBudget = 36_000

    private let workerBaseURL: String

    /// Transcript segments per video id. An empty array means "this video has no
    /// transcript" (see `noTranscriptNotedAtByVideoId` for how long that is
    /// believed). Network failures are not cached.
    private var cachedTranscriptSegmentsByVideoId: [String: [YouTubeTranscriptSegment]] = [:]
    /// When the worker last said a video has no transcript, so the answer expires.
    private var noTranscriptNotedAtByVideoId: [String: Date] = [:]

    /// In-flight transcript downloads, so a prefetch on key-down and the real
    /// fetch after transcription share one request.
    private var inFlightTranscriptFetchTasksByVideoId: [String: Task<[YouTubeTranscriptSegment]?, Never>] = [:]

    /// Generous, because the worker's lookup can take ten seconds or more on
    /// a cold video (YouTube's player endpoint is slow, and the watch-page
    /// fallback downloads a megabyte and a half). The download starts on
    /// key-down and keeps going in the background; how long an answer waits
    /// for it is decided separately (`secondsToWaitForTranscript...`).
    private let transcriptURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// How long an ordinary question waits for a transcript still on its way
    /// before answering from the screenshot alone (the download continues
    /// and is cached for the next ask).
    private let secondsToWaitForTranscriptForAnOrdinaryQuestion: Double = 6
    /// A rewind question is useless without the transcript, so it waits
    /// about as long as the worker could possibly take.
    private let secondsToWaitForTranscriptForARewindQuestion: Double = 28
    /// A "no transcript" answer is remembered only this long: YouTube's
    /// caption endpoints are flaky, and a transient miss must not turn a
    /// whole viewing session into "this video has no transcript".
    private let secondsANoTranscriptAnswerIsRemembered: Double = 120

    init(workerBaseURL: String = "http://localhost:8787") {
        self.workerBaseURL = workerBaseURL
    }

    // MARK: Playback control

    /// Reads the YouTube player state in the frontmost browser without changing it.
    /// Returns nil when the frontmost app isn't a supported browser on a YouTube video.
    func captureFrontmostYouTubeVideoSnapshot() async -> YouTubeVideoPlaybackSnapshot? {
        return await runPlayerScriptInFrontmostBrowser(playerAction: .readStateOnly)
    }

    /// Call on push-to-talk key-down. Captures the video id, title and current time,
    /// pauses the video if it was playing, and starts downloading the transcript in
    /// the background so it is usually cached by the time the question is transcribed.
    @discardableResult
    func pauseVideo() async -> YouTubeVideoPlaybackSnapshot? {
        guard let playbackSnapshot = await runPlayerScriptInFrontmostBrowser(playerAction: .pauseIfPlaying) else {
            return nil
        }
        mostRecentPausedVideoSnapshot = playbackSnapshot
        didWePauseTheMostRecentVideo = !playbackSnapshot.wasPausedBeforeWeActed
        prefetchTranscript(videoId: playbackSnapshot.videoId)
        return playbackSnapshot
    }

    /// Call when the spoken answer and any explainer video are done. Plays the video
    /// again only if it was playing when `pauseVideo()` paused it, and only in a tab
    /// that is still on the same video.
    func resumeVideoIfWePausedIt() async {
        guard didWePauseTheMostRecentVideo, let pausedVideoSnapshot = mostRecentPausedVideoSnapshot else {
            return
        }
        didWePauseTheMostRecentVideo = false

        let resumeAppleScriptSource = Self.buildAppleScriptSourceForTabOnVideo(
            browser: pausedVideoSnapshot.browser,
            videoId: pausedVideoSnapshot.videoId,
            tabJavaScript: Self.buildResumeJavaScript(videoId: pausedVideoSnapshot.videoId),
            timeoutSeconds: Self.appleScriptTimeoutSeconds
        )
        let resumeExecutionResult = await YouTubeBrowserAppleScriptRunner.runAppleScriptOffMainThread(
            appleScriptSource: resumeAppleScriptSource,
            timeoutSeconds: Self.appleScriptTimeoutSeconds
        )
        if case .failed(let errorNumber, let errorMessage) = resumeExecutionResult {
            print("⚠️ YouTube resume failed (\(errorNumber)): \(errorMessage)")
            updateBrowserSetupProblemMessage(browser: pausedVideoSnapshot.browser, errorNumber: errorNumber, errorMessage: errorMessage)
        }
    }

    /// Call when the tutor answered with a `[SEEK:]` tag: jumps the video to
    /// `targetSeconds` (a little earlier, so the first word isn't clipped) and
    /// plays it, whether or not it was playing before: they asked to go there.
    /// Clears the resume flag so the usual end-of-answer resume doesn't fire
    /// on top of it. Only acts on the video the question was asked over.
    func seekVideoAndPlay(toSeconds targetSeconds: Double) async {
        guard let pausedVideoSnapshot = mostRecentPausedVideoSnapshot else {
            print("⚠️ YouTube seek skipped: no video snapshot for this question")
            return
        }
        didWePauseTheMostRecentVideo = false

        let seekTargetSeconds = max(0, targetSeconds - Self.seekLeadInSeconds)
        let seekAppleScriptSource = Self.buildAppleScriptSourceForTabOnVideo(
            browser: pausedVideoSnapshot.browser,
            videoId: pausedVideoSnapshot.videoId,
            tabJavaScript: Self.buildSeekAndPlayJavaScript(videoId: pausedVideoSnapshot.videoId, targetSeconds: seekTargetSeconds),
            timeoutSeconds: Self.seekAppleScriptTimeoutSeconds
        )
        // The answer is over, so nothing waits on this: give the browser a
        // few seconds and try once more if it didn't land, because the seek
        // is the whole point of a rewind answer.
        for attemptNumber in 1...2 {
            let seekExecutionResult = await YouTubeBrowserAppleScriptRunner.runAppleScriptOffMainThread(
                appleScriptSource: seekAppleScriptSource,
                timeoutSeconds: Self.seekAppleScriptTimeoutSeconds
            )
            switch seekExecutionResult {
            case .succeeded(let scriptResultString):
                print("⏪ YouTube seek to \(Self.formatTimestampForTranscript(seekTargetSeconds)) (attempt \(attemptNumber)): \(scriptResultString)")
                if scriptResultString.contains("\"sought\":true") { return }
            case .failed(let errorNumber, let errorMessage):
                print("⚠️ YouTube seek failed (\(errorNumber)): \(errorMessage)")
                updateBrowserSetupProblemMessage(browser: pausedVideoSnapshot.browser, errorNumber: errorNumber, errorMessage: errorMessage)
                return
            case .timedOut:
                print("⚠️ YouTube seek attempt \(attemptNumber) timed out; the browser didn't answer within \(Self.seekAppleScriptTimeoutSeconds)s")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// Seeks land this many seconds before the transcript stamp, because a
    /// caption's stamp is when its first word is spoken.
    private static let seekLeadInSeconds: Double = 1.5

    /// Seeking runs after the answer, so unlike the pause on key-down it can
    /// afford to wait for a busy browser (and for an earlier script still
    /// queued ahead of it on the serial AppleScript queue).
    private static let seekAppleScriptTimeoutSeconds: Double = 4.0

    // MARK: Learning context

    /// Builds the context for the video paused by the most recent `pauseVideo()` call.
    /// Pass `includeFullTranscriptForSeeking` when the question asks to find a
    /// moment in the video, so the tutor sees the whole transcript, not just
    /// the last ninety seconds.
    func learningContextForMostRecentPausedVideo(includeFullTranscriptForSeeking: Bool = false) async -> YouTubeLearningContext? {
        guard let mostRecentPausedVideoSnapshot else { return nil }
        return await learningContext(for: mostRecentPausedVideoSnapshot, includeFullTranscriptForSeeking: includeFullTranscriptForSeeking)
    }

    /// Builds the context for a snapshot: title, timestamp and the ~90 seconds of
    /// transcript before the current time. Never throws; a missing transcript just
    /// leaves `transcriptWindowText` nil so the tutor falls back to the screenshot.
    func learningContext(
        for playbackSnapshot: YouTubeVideoPlaybackSnapshot,
        includeFullTranscriptForSeeking: Bool = false
    ) async -> YouTubeLearningContext {
        let transcriptSegments = await transcriptSegments(
            videoId: playbackSnapshot.videoId,
            waitingAtMostSeconds: includeFullTranscriptForSeeking
                ? secondsToWaitForTranscriptForARewindQuestion
                : secondsToWaitForTranscriptForAnOrdinaryQuestion
        )
        let transcriptWindowText = transcriptSegments.flatMap { segments in
            Self.formatTranscriptWindow(
                transcriptSegments: segments,
                endingAtSeconds: playbackSnapshot.currentTimeSeconds,
                windowLengthSeconds: transcriptWindowLengthSeconds
            )
        }
        let fullTranscriptForSeekingText = includeFullTranscriptForSeeking
            ? transcriptSegments.flatMap { segments in
                Self.formatFullTranscriptForSeeking(
                    transcriptSegments: segments,
                    currentTimeSeconds: playbackSnapshot.currentTimeSeconds,
                    characterBudget: fullTranscriptCharacterBudget
                )
            }
            : nil
        return YouTubeLearningContext(
            videoId: playbackSnapshot.videoId,
            title: playbackSnapshot.title,
            currentTimeSeconds: playbackSnapshot.currentTimeSeconds,
            transcriptWindowText: transcriptWindowText,
            fullTranscriptForSeekingText: fullTranscriptForSeekingText
        )
    }

    /// Convenience for "is the user on a YouTube video right now, and what are they
    /// looking at", without pausing anything.
    func learningContextForFrontmostVideo() async -> YouTubeLearningContext? {
        guard let playbackSnapshot = await captureFrontmostYouTubeVideoSnapshot() else { return nil }
        return await learningContext(for: playbackSnapshot)
    }

    // MARK: Transcript fetching and caching

    /// Starts the download on key-down so it is usually cached by the time
    /// the question is transcribed. The wait here only bounds this task; the
    /// download itself runs to completion either way.
    private func prefetchTranscript(videoId: String) {
        Task { _ = await transcriptSegments(videoId: videoId, waitingAtMostSeconds: secondsToWaitForTranscriptForARewindQuestion) }
    }

    /// Returns cached segments, joins an in-flight download, or starts one,
    /// but waits at most `waitingAtMostSeconds`: past that the caller goes on
    /// without a transcript while the download finishes in the background
    /// and lands in the cache for the next ask. Returns nil when the video
    /// has no transcript, the worker is unreachable, or the wait ran out.
    private func transcriptSegments(videoId: String, waitingAtMostSeconds: Double) async -> [YouTubeTranscriptSegment]? {
        if let cachedTranscriptSegments = cachedTranscriptSegmentsByVideoId[videoId] {
            if !cachedTranscriptSegments.isEmpty { return cachedTranscriptSegments }
            // A "no transcript" answer is believed for a while, then asked again.
            if let noTranscriptNotedAt = noTranscriptNotedAtByVideoId[videoId],
               Date().timeIntervalSince(noTranscriptNotedAt) < secondsANoTranscriptAnswerIsRemembered {
                return nil
            }
            cachedTranscriptSegmentsByVideoId[videoId] = nil
        }

        let transcriptFetchTask: Task<[YouTubeTranscriptSegment]?, Never>
        if let inFlightTranscriptFetchTask = inFlightTranscriptFetchTasksByVideoId[videoId] {
            transcriptFetchTask = inFlightTranscriptFetchTask
        } else {
            transcriptFetchTask = Task<[YouTubeTranscriptSegment]?, Never> { [weak self] in
                // One retry: YouTube's caption endpoints fail transiently, and
                // the worker answers 503 for exactly that case.
                var downloadedSegments = await self?.downloadTranscriptSegmentsFromWorker(videoId: videoId)
                if case .retryLater? = downloadedSegments {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    downloadedSegments = await self?.downloadTranscriptSegmentsFromWorker(videoId: videoId)
                }
                if case .segments(let segments)? = downloadedSegments { return segments }
                return nil
            }
            inFlightTranscriptFetchTasksByVideoId[videoId] = transcriptFetchTask
            Task { [weak self] in
                _ = await transcriptFetchTask.value
                self?.inFlightTranscriptFetchTasksByVideoId[videoId] = nil
            }
        }

        // Race the download against the wait; the download itself is never cancelled.
        return await withTaskGroup(of: [YouTubeTranscriptSegment]??.self) { taskGroup in
            taskGroup.addTask { await transcriptFetchTask.value }
            taskGroup.addTask {
                try? await Task.sleep(nanoseconds: UInt64(waitingAtMostSeconds * 1_000_000_000))
                return .none
            }
            let firstToFinish = await taskGroup.next() ?? .none
            taskGroup.cancelAll()
            if case .some(let segments) = firstToFinish { return segments }
            print("⏳ Transcript for YouTube video \(videoId) is still downloading after \(Int(waitingAtMostSeconds))s; answering without it")
            return nil
        }
    }

    private enum TranscriptDownloadOutcome {
        case segments([YouTubeTranscriptSegment])
        case noTranscript
        case retryLater
        case failed
    }

    private func downloadTranscriptSegmentsFromWorker(videoId: String) async -> TranscriptDownloadOutcome {
        guard let transcriptURL = URL(string: "\(workerBaseURL)/youtube/\(videoId)/transcript") else { return .failed }

        struct WorkerTranscriptResponse: Decodable {
            let segments: [YouTubeTranscriptSegment]
        }

        let startedAt = Date()
        do {
            let (responseData, urlResponse) = try await transcriptURLSession.data(from: transcriptURL)
            let httpStatusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
            let elapsedSeconds = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
            if httpStatusCode == 404 {
                // The video has no English transcript, as far as YouTube says
                // right now; remembered for a couple of minutes, not forever.
                cachedTranscriptSegmentsByVideoId[videoId] = []
                noTranscriptNotedAtByVideoId[videoId] = Date()
                print("📺 No transcript available for YouTube video \(videoId) (\(elapsedSeconds))")
                return .noTranscript
            }
            guard httpStatusCode == 200 else {
                print("⚠️ YouTube transcript fetch for \(videoId) returned HTTP \(httpStatusCode) after \(elapsedSeconds)")
                return httpStatusCode == 503 || httpStatusCode == 502 ? .retryLater : .failed
            }
            let workerTranscriptResponse = try JSONDecoder().decode(WorkerTranscriptResponse.self, from: responseData)
            guard !workerTranscriptResponse.segments.isEmpty else { return .retryLater }
            cachedTranscriptSegmentsByVideoId[videoId] = workerTranscriptResponse.segments
            print("📺 Cached \(workerTranscriptResponse.segments.count) transcript segments for YouTube video \(videoId) (\(elapsedSeconds))")
            return .segments(workerTranscriptResponse.segments)
        } catch {
            print("⚠️ YouTube transcript fetch for \(videoId) failed after \(String(format: "%.1fs", Date().timeIntervalSince(startedAt))): \(error.localizedDescription)")
            return .failed
        }
    }

    // MARK: Formatting

    /// Keeps the segments that overlap `[endingAtSeconds - windowLengthSeconds, endingAtSeconds]`
    /// and formats each as "[mm:ss] text". Returns nil when nothing overlaps.
    static func formatTranscriptWindow(
        transcriptSegments: [YouTubeTranscriptSegment],
        endingAtSeconds: Double,
        windowLengthSeconds: Double
    ) -> String? {
        let windowStartSeconds = max(0, endingAtSeconds - windowLengthSeconds)
        let segmentsInsideWindow = transcriptSegments.filter { segment in
            let segmentEndSeconds = segment.start + segment.duration
            return segment.start <= endingAtSeconds && segmentEndSeconds >= windowStartSeconds
        }
        guard !segmentsInsideWindow.isEmpty else { return nil }
        return segmentsInsideWindow
            .map { segment in "[\(formatTimestampForTranscript(segment.start))] \(segment.text)" }
            .joined(separator: "\n")
    }

    /// 75.4 → "01:15", 3725 → "1:02:05".
    static func formatTimestampForTranscript(_ totalSecondsAsDouble: Double) -> String {
        let totalWholeSeconds = max(0, Int(totalSecondsAsDouble.rounded(.down)))
        let hours = totalWholeSeconds / 3600
        let minutes = (totalWholeSeconds % 3600) / 60
        let seconds = totalWholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The whole transcript as "[mm:ss] text" lines with a "you are here" marker
    /// at `currentTimeSeconds`, trimmed to `characterBudget` by dropping the
    /// lines furthest from the current time: what was watched keeps about two
    /// thirds of the budget, what is still to come gets the rest, and either
    /// side takes over space the other doesn't need. Nil for an empty transcript.
    static func formatFullTranscriptForSeeking(
        transcriptSegments: [YouTubeTranscriptSegment],
        currentTimeSeconds: Double,
        characterBudget: Int
    ) -> String? {
        guard !transcriptSegments.isEmpty else { return nil }
        let formattedLines = transcriptSegments.map { segment in
            "[\(formatTimestampForTranscript(segment.start))] \(segment.text)"
        }
        let firstLineIndexAfterCurrentTime = transcriptSegments.firstIndex { $0.start > currentTimeSeconds } ?? transcriptSegments.count
        let linesBefore = Array(formattedLines[..<firstLineIndexAfterCurrentTime])
        let linesAfter = Array(formattedLines[firstLineIndexAfterCurrentTime...])

        func characterCount(of lines: [String]) -> Int { lines.reduce(0) { $0 + $1.count + 1 } }
        let preferredBudgetBefore = characterBudget * 2 / 3
        let budgetBefore = max(preferredBudgetBefore, characterBudget - characterCount(of: linesAfter))
        var keptLinesBefore: [String] = []
        var charactersBefore = 0
        for line in linesBefore.reversed() {
            if charactersBefore + line.count + 1 > budgetBefore { break }
            keptLinesBefore.insert(line, at: 0)
            charactersBefore += line.count + 1
        }
        let budgetAfter = characterBudget - charactersBefore
        var keptLinesAfter: [String] = []
        var charactersAfter = 0
        for line in linesAfter {
            if charactersAfter + line.count + 1 > budgetAfter { break }
            keptLinesAfter.append(line)
            charactersAfter += line.count + 1
        }

        var outputLines: [String] = []
        if keptLinesBefore.count < linesBefore.count { outputLines.append("[... earlier part of the video left out ...]") }
        outputLines.append(contentsOf: keptLinesBefore)
        outputLines.append("---- you are here (\(formatTimestampForTranscript(currentTimeSeconds))) ----")
        outputLines.append(contentsOf: keptLinesAfter)
        if keptLinesAfter.count < linesAfter.count { outputLines.append("[... rest of the video left out ...]") }
        return outputLines.joined(separator: "\n")
    }

    /// "6:52" → 412, "1:02:05" → 3725, "412" → 412. Nil for anything else
    /// (including "none"), so a malformed seek tag is ignored, never acted on.
    static func parseTimestampToSeconds(_ timestampText: String) -> Double? {
        // Keep only digits, colons and dots, so "at 6:52", "06:52s" or a stray
        // quote around the stamp still parse; "none" becomes empty and fails.
        let trimmedTimestampText = timestampText.filter { $0.isNumber || $0 == ":" || $0 == "." }
        guard !trimmedTimestampText.isEmpty else { return nil }
        let timestampParts = trimmedTimestampText.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...3).contains(timestampParts.count) else { return nil }
        var totalSeconds: Double = 0
        for timestampPart in timestampParts {
            guard let partValue = Double(timestampPart), partValue >= 0 else { return nil }
            totalSeconds = totalSeconds * 60 + partValue
        }
        return totalSeconds
    }

    // MARK: Video id parsing

    /// Pulls the 11-character video id out of youtube.com/watch?v=, youtu.be/,
    /// youtube.com/shorts/, youtube.com/live/ and youtube.com/embed/ URLs.
    static func extractYouTubeVideoId(fromURLString urlString: String) -> String? {
        guard let urlComponents = URLComponents(string: urlString),
              let lowercasedHost = urlComponents.host?.lowercased() else {
            return nil
        }

        let isYouTubeHost = lowercasedHost == "youtube.com" || lowercasedHost.hasSuffix(".youtube.com")
        let isShortLinkHost = lowercasedHost == "youtu.be" || lowercasedHost == "www.youtu.be"
        let pathComponentsWithoutSlashes = urlComponents.path.split(separator: "/").map(String.init)

        var candidateVideoId: String?
        if isShortLinkHost {
            candidateVideoId = pathComponentsWithoutSlashes.first
        } else if isYouTubeHost {
            if urlComponents.path == "/watch" {
                candidateVideoId = urlComponents.queryItems?.first(where: { $0.name == "v" })?.value
            } else if pathComponentsWithoutSlashes.count >= 2,
                      ["shorts", "live", "embed"].contains(pathComponentsWithoutSlashes[0]) {
                candidateVideoId = pathComponentsWithoutSlashes[1]
            }
        }

        guard let candidateVideoId, isValidYouTubeVideoId(candidateVideoId) else { return nil }
        return candidateVideoId
    }

    /// YouTube ids are exactly 11 characters of [A-Za-z0-9_-]. Validating also makes
    /// the id safe to embed in the JavaScript and AppleScript we generate.
    static func isValidYouTubeVideoId(_ candidateVideoId: String) -> Bool {
        guard candidateVideoId.count == 11 else { return false }
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return candidateVideoId.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    // MARK: - Browser scripting

    /// Generous enough for a warm browser (queries take ~20–100ms), short enough
    /// that a hung browser never stalls push-to-talk.
    private static let appleScriptTimeoutSeconds: Double = 1.0

    private enum YouTubePlayerAction {
        case readStateOnly
        case pauseIfPlaying
    }

    /// The JSON our injected JavaScript returns.
    private struct PlayerStateFromJavaScript: Decodable {
        let hasVideo: Bool
        let url: String
        let title: String
        let currentTime: Double?
        let paused: Bool?
    }

    /// Markers the AppleScript returns instead of JSON when there's nothing to do.
    private static let noBrowserWindowMarker = "NO_WINDOW"
    private static let notOnYouTubeMarker = "NOT_YOUTUBE"

    private func runPlayerScriptInFrontmostBrowser(playerAction: YouTubePlayerAction) async -> YouTubeVideoPlaybackSnapshot? {
        guard let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let frontmostBrowser = YouTubeSupportedBrowser.browserForBundleIdentifier(frontmostBundleIdentifier) else {
            return nil
        }

        let playerAppleScriptSource = Self.buildFrontTabPlayerAppleScriptSource(
            browser: frontmostBrowser,
            playerJavaScript: Self.buildPlayerJavaScript(playerAction: playerAction)
        )
        let playerExecutionResult = await YouTubeBrowserAppleScriptRunner.runAppleScriptOffMainThread(
            appleScriptSource: playerAppleScriptSource,
            timeoutSeconds: Self.appleScriptTimeoutSeconds
        )

        switch playerExecutionResult {
        case .timedOut:
            // Most often the first-run macOS Automation prompt is on screen, or the
            // browser is busy. Don't block; the next press will try again.
            print("⚠️ YouTube: \(frontmostBrowser.displayName) did not answer within \(Self.appleScriptTimeoutSeconds)s")
            return nil
        case .failed(let errorNumber, let errorMessage):
            print("⚠️ YouTube: \(frontmostBrowser.displayName) AppleScript error \(errorNumber): \(errorMessage)")
            updateBrowserSetupProblemMessage(browser: frontmostBrowser, errorNumber: errorNumber, errorMessage: errorMessage)
            return nil
        case .succeeded(let scriptResultString):
            browserSetupProblemMessage = nil
            if scriptResultString == Self.noBrowserWindowMarker || scriptResultString == Self.notOnYouTubeMarker {
                return nil
            }
            guard let scriptResultData = scriptResultString.data(using: .utf8),
                  let playerState = try? JSONDecoder().decode(PlayerStateFromJavaScript.self, from: scriptResultData),
                  playerState.hasVideo,
                  let videoId = Self.extractYouTubeVideoId(fromURLString: playerState.url) else {
                return nil
            }
            return YouTubeVideoPlaybackSnapshot(
                browser: frontmostBrowser,
                pageURLString: playerState.url,
                videoId: videoId,
                title: playerState.title,
                currentTimeSeconds: playerState.currentTime ?? 0,
                wasPausedBeforeWeActed: playerState.paused ?? true
            )
        }
    }

    /// Turns AppleScript errors into a message the user can act on.
    private func updateBrowserSetupProblemMessage(browser: YouTubeSupportedBrowser, errorNumber: Int, errorMessage: String) {
        let lowercasedErrorMessage = errorMessage.lowercased()
        let isJavaScriptFromAppleEventsDisabled =
            lowercasedErrorMessage.contains("javascript through applescript is turned off")
            || lowercasedErrorMessage.contains("allow javascript from apple events")

        if isJavaScriptFromAppleEventsDisabled {
            browserSetupProblemMessage = browser.allowJavaScriptFromAppleEventsInstructions
        } else if errorNumber == -1743 {
            // errAEEventNotPermitted: the user said "Don't Allow" to the Automation prompt.
            browserSetupProblemMessage = "I'm not allowed to talk to \(browser.displayName). Turn it on in System Settings → Privacy & Security → Automation → \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this app") → \(browser.displayName)."
        } else {
            browserSetupProblemMessage = nil
        }

        if let browserSetupProblemMessage {
            print("📺 YouTube setup needed: \(browserSetupProblemMessage)")
        }
    }

    /// JavaScript run inside the YouTube tab. Returns a JSON string with
    /// `{hasVideo, url, title, currentTime, paused}`; `paused` is the state
    /// before any action. Uses YouTube's own player API when available so the
    /// on-screen controls stay in sync, and falls back to the <video> element.
    private static func buildPlayerJavaScript(playerAction: YouTubePlayerAction) -> String {
        let actionJavaScript: String
        switch playerAction {
        case .readStateOnly:
            actionJavaScript = ""
        case .pauseIfPlaying:
            actionJavaScript = """
            if (!wasPaused) { if (moviePlayer && typeof moviePlayer.pauseVideo === 'function') { moviePlayer.pauseVideo(); } else { video.pause(); } }
            """
        }

        return """
        (function () {
          var moviePlayer = document.getElementById('movie_player');
          var video = document.querySelector('ytd-reel-video-renderer[is-active] video')
            || document.querySelector('#movie_player video')
            || document.querySelector('video');
          var title = (document.title || '').replace(/^\\(\\d+\\)\\s*/, '').replace(/\\s*-\\s*YouTube$/, '');
          if (!video) { return JSON.stringify({ hasVideo: false, url: location.href, title: title }); }
          var wasPaused = video.paused;
          var currentTime = video.currentTime;
          \(actionJavaScript)
          return JSON.stringify({ hasVideo: true, url: location.href, title: title, currentTime: currentTime, paused: wasPaused });
        })();
        """
    }

    /// AppleScript that checks the front tab is on YouTube and, if so, runs
    /// `playerJavaScript` in it and returns the result.
    private static func buildFrontTabPlayerAppleScriptSource(browser: YouTubeSupportedBrowser, playerJavaScript: String) -> String {
        let escapedPlayerJavaScript = escapeForAppleScriptStringLiteral(playerJavaScript)
        let timeoutWholeSeconds = Int(appleScriptTimeoutSeconds.rounded(.up))

        switch browser {
        case .chromiumBased(let bundleIdentifier, _):
            return """
            tell application id "\(bundleIdentifier)"
                with timeout of \(timeoutWholeSeconds) seconds
                    if (count of windows) is 0 then return "\(noBrowserWindowMarker)"
                    set activeTabURL to URL of active tab of front window
                    if activeTabURL does not contain "youtube.com/" and activeTabURL does not contain "youtu.be/" then return "\(notOnYouTubeMarker)"
                    tell active tab of front window to return (execute javascript "\(escapedPlayerJavaScript)")
                end timeout
            end tell
            """
        case .safari:
            return """
            tell application id "com.apple.Safari"
                with timeout of \(timeoutWholeSeconds) seconds
                    if (count of windows) is 0 then return "\(noBrowserWindowMarker)"
                    set activeTabURL to URL of current tab of front window
                    if activeTabURL does not contain "youtube.com/" and activeTabURL does not contain "youtu.be/" then return "\(notOnYouTubeMarker)"
                    return (do JavaScript "\(escapedPlayerJavaScript)" in current tab of front window)
                end timeout
            end tell
            """
        }
    }

    /// JavaScript that plays the video if it is paused. `videoId` was validated
    /// to [A-Za-z0-9_-]{11}, so it is safe to embed directly.
    private static func buildResumeJavaScript(videoId: String) -> String {
        """
        (function () {
          if (location.href.indexOf('\(videoId)') === -1) { return 'WRONG_VIDEO'; }
          var moviePlayer = document.getElementById('movie_player');
          var video = document.querySelector('ytd-reel-video-renderer[is-active] video')
            || document.querySelector('#movie_player video')
            || document.querySelector('video');
          if (!video || !video.paused) { return 'NOTHING_TO_RESUME'; }
          if (moviePlayer && typeof moviePlayer.playVideo === 'function') { moviePlayer.playVideo(); } else { video.play(); }
          return 'RESUMED';
        })();
        """
    }

    /// JavaScript that jumps to `targetSeconds` and plays. YouTube's own
    /// `seekTo` keeps the progress bar and captions in sync; the raw <video>
    /// element is the fallback. `targetSeconds` is a number we computed, never
    /// model text, so it is safe to interpolate.
    private static func buildSeekAndPlayJavaScript(videoId: String, targetSeconds: Double) -> String {
        let formattedTargetSeconds = String(format: "%.1f", targetSeconds)
        return """
        (function () {
          if (location.href.indexOf('\(videoId)') === -1) { return 'WRONG_VIDEO'; }
          var moviePlayer = document.getElementById('movie_player');
          var video = document.querySelector('ytd-reel-video-renderer[is-active] video')
            || document.querySelector('#movie_player video')
            || document.querySelector('video');
          if (!video) { return 'NO_VIDEO'; }
          var target = \(formattedTargetSeconds);
          if (moviePlayer && typeof moviePlayer.seekTo === 'function') { moviePlayer.seekTo(target, true); } else { video.currentTime = target; }
          if (moviePlayer && typeof moviePlayer.playVideo === 'function') { moviePlayer.playVideo(); } else { video.play(); }
          var landed = Math.abs(video.currentTime - target) < 3;
          return JSON.stringify({ sought: landed, currentTime: video.currentTime, paused: video.paused });
        })();
        """
    }

    /// AppleScript that finds the first tab on `videoId` (the user may have switched
    /// tabs while we were answering) and runs `tabJavaScript` in it.
    private static func buildAppleScriptSourceForTabOnVideo(
        browser: YouTubeSupportedBrowser,
        videoId: String,
        tabJavaScript: String,
        timeoutSeconds: Double
    ) -> String {
        let escapedResumeJavaScript = escapeForAppleScriptStringLiteral(tabJavaScript)
        let timeoutWholeSeconds = Int(timeoutSeconds.rounded(.up))

        switch browser {
        case .chromiumBased(let bundleIdentifier, _):
            return """
            tell application id "\(bundleIdentifier)"
                with timeout of \(timeoutWholeSeconds) seconds
                    repeat with candidateWindow in windows
                        set matchingTabs to (tabs of candidateWindow whose URL contains "\(videoId)")
                        if (count of matchingTabs) > 0 then
                            tell (item 1 of matchingTabs) to return (execute javascript "\(escapedResumeJavaScript)")
                        end if
                    end repeat
                    return "NO_MATCHING_TAB"
                end timeout
            end tell
            """
        case .safari:
            return """
            tell application id "com.apple.Safari"
                with timeout of \(timeoutWholeSeconds) seconds
                    repeat with candidateWindow in windows
                        set matchingTabs to (tabs of candidateWindow whose URL contains "\(videoId)")
                        if (count of matchingTabs) > 0 then
                            return (do JavaScript "\(escapedResumeJavaScript)" in (item 1 of matchingTabs))
                        end if
                    end repeat
                    return "NO_MATCHING_TAB"
                end timeout
            end tell
            """
        }
    }

    /// AppleScript string literals only need backslashes and double quotes escaped.
    /// Newlines are flattened so the literal stays on one line.
    private static func escapeForAppleScriptStringLiteral(_ unescapedText: String) -> String {
        return unescapedText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - AppleScript runner (off the main thread)

/// The outcome of running one AppleScript.
nonisolated enum YouTubeAppleScriptExecutionResult: Sendable {
    case succeeded(resultString: String)
    case failed(errorNumber: Int, errorMessage: String)
    case timedOut
}

/// Runs NSAppleScript on a dedicated serial background queue and stops waiting
/// after a deadline. NSAppleScript can't be cancelled, so a script that overruns
/// keeps running in the background, but the caller gets `.timedOut` on time and
/// is never blocked.
nonisolated enum YouTubeBrowserAppleScriptRunner {

    /// Serial because NSAppleScript is not safe to run concurrently from many threads.
    private static let appleScriptExecutionQueue = DispatchQueue(
        label: "YouTubeContextProvider.appleScriptExecution",
        qos: .userInitiated
    )

    static func runAppleScriptOffMainThread(appleScriptSource: String, timeoutSeconds: Double) async -> YouTubeAppleScriptExecutionResult {
        return await withCheckedContinuation { (continuation: CheckedContinuation<YouTubeAppleScriptExecutionResult, Never>) in
            let continuationResumeOnceGuard = ContinuationResumeOnceGuard()

            appleScriptExecutionQueue.async {
                let executionResult = executeAppleScriptSynchronously(appleScriptSource: appleScriptSource)
                if continuationResumeOnceGuard.claimTheOnlyResume() {
                    continuation.resume(returning: executionResult)
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                if continuationResumeOnceGuard.claimTheOnlyResume() {
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    private static func executeAppleScriptSynchronously(appleScriptSource: String) -> YouTubeAppleScriptExecutionResult {
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            return .failed(errorNumber: 0, errorMessage: "could not create NSAppleScript")
        }
        var errorInformation: NSDictionary?
        let resultDescriptor = appleScript.executeAndReturnError(&errorInformation)
        if let errorInformation {
            let errorNumber = errorInformation[NSAppleScript.errorNumber] as? Int ?? 0
            let errorMessage = errorInformation[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
            // -1712 is errAETimeout: our own `with timeout` fired.
            if errorNumber == -1712 {
                return .timedOut
            }
            return .failed(errorNumber: errorNumber, errorMessage: errorMessage)
        }
        return .succeeded(resultString: resultDescriptor.stringValue ?? "")
    }
}

/// Makes sure a continuation is resumed exactly once when two paths (the script
/// finishing and the timeout firing) race to resume it.
nonisolated final class ContinuationResumeOnceGuard: @unchecked Sendable {
    private let resumeLock = NSLock()
    private var hasAlreadyResumed = false

    func claimTheOnlyResume() -> Bool {
        resumeLock.lock()
        defer { resumeLock.unlock() }
        if hasAlreadyResumed { return false }
        hasAlreadyResumed = true
        return true
    }
}
