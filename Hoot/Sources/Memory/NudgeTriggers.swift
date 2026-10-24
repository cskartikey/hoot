//
//  NudgeTriggers.swift
//  Hoot
//
//  The two nudge triggers that live outside the memory core (the review
//  nudge is posted by the spaced-review code):
//
//   - video ready while away: an explainer finished after the learner
//     closed the panel → "your animation's ready: <title>" [▶ play] [later]
//   - same idea as before: while a YouTube video plays in the front
//     browser, about once a minute the last ~45s of transcript is matched
//     against past memories; a strong match (≥ 0.80) → "psst, this is the
//     same idea as <concept> from tuesday." [show me] [got it]
//

import AppKit
import Foundation

/// Installs the nudge triggers that live outside the memory core
/// (video ready while away, same idea as before). Called once by the app
/// delegate after launch.
@MainActor
enum NudgeTriggers {
    /// Optional: what "show me" does when the matched memory has no saved
    /// video (e.g. open the menu panel on that concept). Set by the app
    /// delegate if it wants; otherwise "show me" just closes the bubble.
    static var onShowMemoryWithoutVideo: ((MemoryEntry) -> Void)?

    /// How long a "your animation's ready" nudge keeps waiting for a moment
    /// the etiquette rules allow.
    private static let videoReadyNudgeWaitLimitSeconds: TimeInterval = 10 * 60

    static func install(hootController: HootController, explainerPanelManager: ExplainerPanelManager) {
        NudgeCenter.shared.hootController = hootController

        explainerPanelManager.onVideoReadyWhileClosed = { [weak explainerPanelManager] videoURL, videoTitle in
            let videoReadyNudge = HootNudge(
                kind: .videoReadyWhileAway,
                message: "your animation's ready: \(videoTitle)",
                emphasizedPhrase: videoTitle,
                primaryButtonTitle: "▶ play",
                primaryAction: { explainerPanelManager?.playSavedVideo(url: videoURL, title: videoTitle) },
                secondaryButtonTitle: "later"
            )
            NudgeCenter.shared.postNudgeWhenAllowed(videoReadyNudge, givingUpAfterSeconds: videoReadyNudgeWaitLimitSeconds)
        }

        SameIdeaNudgeWatcher.shared.start(hootController: hootController, explainerPanelManager: explainerPanelManager)
    }
}

// MARK: - Same idea as before

/// Watches the YouTube video playing in the front browser and, when what's
/// being said matches something the learner asked about before, offers to
/// show that old answer again.
@MainActor
final class SameIdeaNudgeWatcher {
    static let shared = SameIdeaNudgeWatcher()

    private weak var hootController: HootController?
    private weak var explainerPanelManager: ExplainerPanelManager?

    private var checkTimer: Timer?
    /// The timer fires about once a minute; this also guards the AppleScript
    /// read so the browser is never asked more than once a minute.
    private let secondsBetweenChecks: TimeInterval = 60
    private var lastBrowserReadDate = Date.distantPast
    private var isCheckRunning = false

    private let transcriptSecondsToMatch: Double = 45
    private let minimumTranscriptCharactersToMatch = 60
    private let minimumSimilarityForSameIdea: Float = 0.80
    /// A memory from the last few minutes is what the learner just asked
    /// about, not a callback worth a nudge.
    private let minimumMemoryAgeSeconds: TimeInterval = 10 * 60

    /// concept → the day ("yyyy-MM-dd") it was last nudged, so each concept
    /// gets at most one "same idea" nudge per day.
    private static let lastNudgedDayByConceptDefaultsKey = "sameIdeaNudgeLastDayByConcept"

    func start(hootController: HootController, explainerPanelManager: ExplainerPanelManager) {
        self.hootController = hootController
        self.explainerPanelManager = explainerPanelManager
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: secondsBetweenChecks, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontmostVideoForSameIdea() }
        }
    }

    private func checkFrontmostVideoForSameIdea() {
        let nudgeCenter = NudgeCenter.shared
        guard !isCheckRunning,
              nudgeCenter.areNudgesEnabled,
              !nudgeCenter.areNudgesPausedRightNow,
              nudgeCenter.currentNudge == nil,
              !nudgeCenter.isHootBusy,
              let hootController,
              Date().timeIntervalSince(lastBrowserReadDate) >= secondsBetweenChecks - 1 else { return }

        // Only ask the browser when a supported one is actually in front,
        // so nothing runs AppleScript against other apps.
        guard let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              YouTubeSupportedBrowser.browserForBundleIdentifier(frontmostBundleIdentifier) != nil else { return }

        isCheckRunning = true
        lastBrowserReadDate = Date()
        let youTubeContextProvider = hootController.youTubeContextProvider
        Task { @MainActor [weak self] in
            defer { self?.isCheckRunning = false }
            // Read-only: never pauses or seeks the learner's video.
            guard let playbackSnapshot = await youTubeContextProvider.captureFrontmostYouTubeVideoSnapshot(),
                  !playbackSnapshot.wasPausedBeforeWeActed else { return }
            let learningContext = await youTubeContextProvider.learningContext(for: playbackSnapshot)
            guard let self,
                  let transcriptWindowText = learningContext.transcriptWindowText,
                  let recentTranscriptText = Self.transcriptText(
                    fromStampedWindow: transcriptWindowText,
                    endingAtSeconds: playbackSnapshot.currentTimeSeconds,
                    lastSeconds: self.transcriptSecondsToMatch
                  ),
                  recentTranscriptText.count >= self.minimumTranscriptCharactersToMatch else { return }
            self.offerSameIdeaNudgeIfAnythingMatches(transcriptText: recentTranscriptText)
        }
    }

    private func offerSameIdeaNudgeIfAnythingMatches(transcriptText: String) {
        guard let bestMatch = MemoryRecall.relatedMemories(
            forQueryText: transcriptText,
            limit: 1,
            minimumSimilarity: minimumSimilarityForSameIdea
        ).first else { return }

        let matchedEntry = bestMatch.entry
        let concept = matchedEntry.concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty,
              Date().timeIntervalSince(matchedEntry.askedAt) >= minimumMemoryAgeSeconds,
              !wasConceptNudgedToday(concept) else { return }

        let relativeDayPhrase = Self.relativeDayPhrase(for: matchedEntry.askedAt)
        let sameIdeaNudge = HootNudge(
            kind: .sameIdeaAsBefore,
            message: "psst, this is the same idea as \(concept) from \(relativeDayPhrase).",
            emphasizedPhrase: concept,
            primaryButtonTitle: "show me",
            primaryAction: { [weak self] in self?.showMemory(matchedEntry) },
            secondaryButtonTitle: "got it"
        )
        if NudgeCenter.shared.postNudgeIfAllowed(sameIdeaNudge) {
            rememberConceptWasNudgedToday(concept)
        }
    }

    /// Replays the memory's explainer video (or the newest one for the same
    /// concept). Without any video, hands off to `onShowMemoryWithoutVideo`.
    private func showMemory(_ matchedEntry: MemoryEntry) {
        let entryWithVideo: MemoryEntry? = matchedEntry.explainerVideoURL != nil
            ? matchedEntry
            : MemoryStore.shared.entries(forConcept: matchedEntry.concept).first { $0.explainerVideoURL != nil }
        if let entryWithVideo, let savedVideoURL = entryWithVideo.explainerVideoURL {
            explainerPanelManager?.playSavedVideo(url: savedVideoURL, title: entryWithVideo.question)
        } else {
            NudgeTriggers.onShowMemoryWithoutVideo?(matchedEntry)
        }
    }

    // MARK: Once per concept per day

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func wasConceptNudgedToday(_ concept: String) -> Bool {
        let lastNudgedDayByConcept = UserDefaults.standard.dictionary(forKey: Self.lastNudgedDayByConceptDefaultsKey) as? [String: String] ?? [:]
        return lastNudgedDayByConcept[concept.lowercased()] == Self.dayKeyFormatter.string(from: Date())
    }

    private func rememberConceptWasNudgedToday(_ concept: String) {
        let todayKey = Self.dayKeyFormatter.string(from: Date())
        var lastNudgedDayByConcept = UserDefaults.standard.dictionary(forKey: Self.lastNudgedDayByConceptDefaultsKey) as? [String: String] ?? [:]
        // Drop older days so the dictionary never grows without bound.
        lastNudgedDayByConcept = lastNudgedDayByConcept.filter { $0.value == todayKey }
        lastNudgedDayByConcept[concept.lowercased()] = todayKey
        UserDefaults.standard.set(lastNudgedDayByConcept, forKey: Self.lastNudgedDayByConceptDefaultsKey)
    }

    // MARK: Text helpers

    /// The provider's window is "[mm:ss] text" lines covering ~90s; keep the
    /// lines from the last `lastSeconds` and drop the stamps.
    static func transcriptText(fromStampedWindow stampedWindowText: String, endingAtSeconds: Double, lastSeconds: Double) -> String? {
        let windowStartSeconds = max(0, endingAtSeconds - lastSeconds)
        var keptTranscriptLines: [String] = []
        for stampedLine in stampedWindowText.split(separator: "\n") {
            guard stampedLine.hasPrefix("["), let closingBracketIndex = stampedLine.firstIndex(of: "]") else { continue }
            let stampText = stampedLine[stampedLine.index(after: stampedLine.startIndex)..<closingBracketIndex]
            let stampParts = stampText.split(separator: ":").compactMap { Double($0) }
            let lineStartSeconds = stampParts.reduce(0) { $0 * 60 + $1 }
            // A line that started a little before the cut still carries words inside it.
            guard lineStartSeconds >= windowStartSeconds - 5 else { continue }
            let lineText = stampedLine[stampedLine.index(after: closingBracketIndex)...]
                .trimmingCharacters(in: .whitespaces)
            if !lineText.isEmpty { keptTranscriptLines.append(lineText) }
        }
        guard !keptTranscriptLines.isEmpty else { return nil }
        return keptTranscriptLines.joined(separator: " ")
    }

    /// "earlier today", "yesterday", "tuesday" (within the week), else "oct 3".
    static func relativeDayPhrase(for pastDate: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: pastDate),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch dayDifference {
        case ..<1:
            return "earlier today"
        case 1:
            return "yesterday"
        case 2...6:
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = Locale(identifier: "en_US")
            weekdayFormatter.dateFormat = "EEEE"
            return weekdayFormatter.string(from: pastDate).lowercased()
        default:
            let shortDateFormatter = DateFormatter()
            shortDateFormatter.locale = Locale(identifier: "en_US")
            shortDateFormatter.dateFormat = "MMM d"
            return shortDateFormatter.string(from: pastDate).lowercased()
        }
    }
}
