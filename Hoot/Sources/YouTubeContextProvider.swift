//
//  YouTubeContextProvider.swift
//  Hoot
//
//  Knows what YouTube video the user is watching in the frontmost browser
//  (Google Chrome, Arc, Brave, Edge or Safari), where they are in it, and what
//  was said in the ninety seconds before that point. Pauses the video while the
//  user asks a question and resumes it afterwards, but only if it was playing
//  when we paused it.
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

    /// The text block to append to the user prompt sent to the tutor.
    var promptContextBlock: String {
        let formattedCurrentTime = YouTubeContextProvider.formatTimestampForTranscript(currentTimeSeconds)
        var promptContextLines = [
            "the user is watching the YouTube video \"\(title)\" (video id \(videoId)) and paused it at \(formattedCurrentTime)."
        ]
        if let transcriptWindowText, !transcriptWindowText.isEmpty {
            promptContextLines.append("here's what was said in the last ninety seconds before they paused (the last lines are what the speaker just said):")
            promptContextLines.append(transcriptWindowText)
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

    private let workerBaseURL: String

    /// Transcript segments per video id. An empty array means "this video has no
    /// transcript" so we don't keep asking. Network failures are not cached.
    private var cachedTranscriptSegmentsByVideoId: [String: [YouTubeTranscriptSegment]] = [:]

    /// In-flight transcript downloads, so a prefetch on key-down and the real
    /// fetch after transcription share one request.
    private var inFlightTranscriptFetchTasksByVideoId: [String: Task<[YouTubeTranscriptSegment]?, Never>] = [:]

    private let transcriptURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

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

        let resumeAppleScriptSource = Self.buildResumeAppleScriptSource(
            browser: pausedVideoSnapshot.browser,
            videoId: pausedVideoSnapshot.videoId
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

    // MARK: Learning context

    /// Builds the context for the video paused by the most recent `pauseVideo()` call.
    func learningContextForMostRecentPausedVideo() async -> YouTubeLearningContext? {
        guard let mostRecentPausedVideoSnapshot else { return nil }
        return await learningContext(for: mostRecentPausedVideoSnapshot)
    }

    /// Builds the context for a snapshot: title, timestamp and the ~90 seconds of
    /// transcript before the current time. Never throws; a missing transcript just
    /// leaves `transcriptWindowText` nil so the tutor falls back to the screenshot.
    func learningContext(for playbackSnapshot: YouTubeVideoPlaybackSnapshot) async -> YouTubeLearningContext {
        let transcriptSegments = await transcriptSegments(videoId: playbackSnapshot.videoId)
        let transcriptWindowText = transcriptSegments.flatMap { segments in
            Self.formatTranscriptWindow(
                transcriptSegments: segments,
                endingAtSeconds: playbackSnapshot.currentTimeSeconds,
                windowLengthSeconds: transcriptWindowLengthSeconds
            )
        }
        return YouTubeLearningContext(
            videoId: playbackSnapshot.videoId,
            title: playbackSnapshot.title,
            currentTimeSeconds: playbackSnapshot.currentTimeSeconds,
            transcriptWindowText: transcriptWindowText
        )
    }

    /// Convenience for "is the user on a YouTube video right now, and what are they
    /// looking at", without pausing anything.
    func learningContextForFrontmostVideo() async -> YouTubeLearningContext? {
        guard let playbackSnapshot = await captureFrontmostYouTubeVideoSnapshot() else { return nil }
        return await learningContext(for: playbackSnapshot)
    }

    // MARK: Transcript fetching and caching

    private func prefetchTranscript(videoId: String) {
        Task { _ = await transcriptSegments(videoId: videoId) }
    }

    /// Returns cached segments, joins an in-flight download, or starts one.
    /// Returns nil when the video has no transcript or the worker is unreachable.
    private func transcriptSegments(videoId: String) async -> [YouTubeTranscriptSegment]? {
        if let cachedTranscriptSegments = cachedTranscriptSegmentsByVideoId[videoId] {
            return cachedTranscriptSegments.isEmpty ? nil : cachedTranscriptSegments
        }
        if let inFlightTranscriptFetchTask = inFlightTranscriptFetchTasksByVideoId[videoId] {
            return await inFlightTranscriptFetchTask.value
        }

        let transcriptFetchTask = Task<[YouTubeTranscriptSegment]?, Never> {
            await downloadTranscriptSegmentsFromWorker(videoId: videoId)
        }
        inFlightTranscriptFetchTasksByVideoId[videoId] = transcriptFetchTask
        let downloadedTranscriptSegments = await transcriptFetchTask.value
        inFlightTranscriptFetchTasksByVideoId[videoId] = nil
        return downloadedTranscriptSegments
    }

    private func downloadTranscriptSegmentsFromWorker(videoId: String) async -> [YouTubeTranscriptSegment]? {
        guard let transcriptURL = URL(string: "\(workerBaseURL)/youtube/\(videoId)/transcript") else { return nil }

        struct WorkerTranscriptResponse: Decodable {
            let segments: [YouTubeTranscriptSegment]
        }

        do {
            let (responseData, urlResponse) = try await transcriptURLSession.data(from: transcriptURL)
            let httpStatusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
            if httpStatusCode == 404 {
                // The video genuinely has no English transcript; remember that.
                cachedTranscriptSegmentsByVideoId[videoId] = []
                print("📺 No transcript available for YouTube video \(videoId)")
                return nil
            }
            guard httpStatusCode == 200 else {
                print("⚠️ YouTube transcript fetch for \(videoId) returned HTTP \(httpStatusCode)")
                return nil
            }
            let workerTranscriptResponse = try JSONDecoder().decode(WorkerTranscriptResponse.self, from: responseData)
            cachedTranscriptSegmentsByVideoId[videoId] = workerTranscriptResponse.segments
            print("📺 Cached \(workerTranscriptResponse.segments.count) transcript segments for YouTube video \(videoId)")
            return workerTranscriptResponse.segments.isEmpty ? nil : workerTranscriptResponse.segments
        } catch {
            print("⚠️ YouTube transcript fetch for \(videoId) failed: \(error.localizedDescription)")
            return nil
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

    /// AppleScript that finds the first tab on `videoId` (the user may have switched
    /// tabs while we were answering) and plays the video if it is paused.
    private static func buildResumeAppleScriptSource(browser: YouTubeSupportedBrowser, videoId: String) -> String {
        // videoId was validated to [A-Za-z0-9_-]{11}, so it is safe to embed directly.
        let resumeJavaScript = """
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
        let escapedResumeJavaScript = escapeForAppleScriptStringLiteral(resumeJavaScript)
        let timeoutWholeSeconds = Int(appleScriptTimeoutSeconds.rounded(.up))

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
