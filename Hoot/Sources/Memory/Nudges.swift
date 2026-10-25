//
//  Nudges.swift
//  Hoot
//
//  Corner nudges: a small bubble beside the dozing corner hoot when it
//  noticed something worth a tap on the shoulder (docs/MEMORY.md §9).
//  NudgeCenter is the single gate every nudge goes through, so the
//  etiquette rules from the design live in one place:
//
//   - the "nudges" setting is on (default on)
//   - at most one nudge every 10 minutes (1 minute in review demo mode)
//   - never while the learner is typing (a key press in the last 5s), while
//     a fullscreen app is in front, or while hoot is answering
//   - one nudge at a time; an untouched nudge fades after 8s (12s for
//     review nudges) and counts as ignored
//   - three ignored in a row → nudges pause until tomorrow
//
//  The bubble itself is drawn by CornerNudgePresenter (UI/CornerNudge*.swift).
//  The triggers that live outside the memory core are in NudgeTriggers.swift.
//

import AppKit
import Combine
import Foundation

// MARK: - Nudges

/// A small bubble beside the corner hoot with up to two buttons.
struct HootNudge: Identifiable {
    enum Kind: String {
        case reviewDue
        case videoReadyWhileAway
        case sameIdeaAsBefore
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// Words in `message` to emphasize (e.g. the concept or video title).
    var emphasizedPhrase: String? = nil
    let primaryButtonTitle: String
    let primaryAction: () -> Void
    let secondaryButtonTitle: String
    var secondaryAction: () -> Void = {}
}

@MainActor
final class NudgeCenter: ObservableObject {
    static let shared = NudgeCenter()

    // MARK: Published state

    /// The nudge on screen right now, if any.
    @Published private(set) var currentNudge: HootNudge?
    /// Settings toggle; persisted. Turning it off clears the nudge on screen
    /// and anything waiting; turning it back on also lifts an ignore-pause.
    @Published var areNudgesEnabled: Bool {
        didSet {
            guard areNudgesEnabled != oldValue else { return }
            UserDefaults.standard.set(areNudgesEnabled, forKey: Self.nudgesEnabledDefaultsKey)
            if areNudgesEnabled {
                resumeNudgesNow()
            } else {
                pendingNudges.removeAll()
                if currentNudge != nil { dismissCurrentNudge(wasIgnored: false) }
            }
        }
    }
    /// Set after three ignored nudges in a row; nil when not paused.
    @Published private(set) var nudgesPausedUntilDate: Date?

    /// The nudge view sets this while the pointer is over the bubble, so a
    /// nudge being read (or about to be clicked) never fades out from under it.
    var isPointerOverCurrentNudge = false

    /// Set by `NudgeTriggers.install`. Weak: the app delegate owns hoot.
    weak var hootController: HootController?

    // MARK: Rules

    private static let nudgesEnabledDefaultsKey = "areNudgesEnabled"
    private static let pausedUntilDefaultsKey = "nudgesPausedUntilDate"
    private static let consecutiveIgnoredCountDefaultsKey = "nudgesConsecutiveIgnoredCount"
    private static let reviewDemoModeDefaultsKey = "hootReviewDemoMode"

    private let minimumSecondsBetweenNudges: TimeInterval = 10 * 60
    private let minimumSecondsBetweenNudgesInDemoMode: TimeInterval = 60
    private let quietSecondsAfterTypingBeforeNudging: TimeInterval = 5
    private let secondsBeforeAnUntouchedNudgeFades: TimeInterval = 8
    private let secondsBeforeAnUntouchedReviewNudgeFades: TimeInterval = 12
    private let ignoredNudgesInARowThatPauseNudges = 3
    /// Demo mode can't wait until tomorrow on stage, so the pause is short there.
    private let pauseLengthInDemoMode: TimeInterval = 5 * 60

    /// Review demo mode: shorter intervals everywhere so the memory features
    /// can be shown in a few minutes (UserDefaults `hootReviewDemoMode` or
    /// the `HOOT_REVIEW_DEMO=1` environment variable).
    var isReviewDemoModeOn: Bool {
        UserDefaults.standard.bool(forKey: Self.reviewDemoModeDefaultsKey)
            || ProcessInfo.processInfo.environment["HOOT_REVIEW_DEMO"] == "1"
    }

    var areNudgesPausedRightNow: Bool {
        guard let nudgesPausedUntilDate else { return false }
        return Date() < nudgesPausedUntilDate
    }

    // MARK: Private state

    private var lastNudgeShownDate: Date?
    private var consecutiveIgnoredNudgeCount: Int {
        didSet { UserDefaults.standard.set(consecutiveIgnoredNudgeCount, forKey: Self.consecutiveIgnoredCountDefaultsKey) }
    }
    private var lastKeyDownDate = Date.distantPast
    private var keyDownMonitors: [Any] = []

    private var autoDismissTimer: Timer?
    /// While a nudge is up: steps it aside if hoot starts answering or a
    /// fullscreen app comes to the front.
    private var shownNudgeWatchTimer: Timer?

    /// Nudges that were refused but are still worth showing for a while
    /// (e.g. "your animation's ready"), retried every few seconds.
    private struct PendingNudge {
        let nudge: HootNudge
        let expiryDate: Date
    }
    private var pendingNudges: [PendingNudge] = []
    private var pendingNudgeRetryTimer: Timer?
    private let pendingNudgeRetryIntervalSeconds: TimeInterval = 5

    private init() {
        let userDefaults = UserDefaults.standard
        if userDefaults.object(forKey: Self.nudgesEnabledDefaultsKey) == nil {
            areNudgesEnabled = true
        } else {
            areNudgesEnabled = userDefaults.bool(forKey: Self.nudgesEnabledDefaultsKey)
        }
        nudgesPausedUntilDate = userDefaults.object(forKey: Self.pausedUntilDefaultsKey) as? Date
        consecutiveIgnoredNudgeCount = userDefaults.integer(forKey: Self.consecutiveIgnoredCountDefaultsKey)
        startWatchingForTyping()
    }

    // MARK: - Posting

    /// Shows the nudge if the etiquette rules allow it (rate limit, not
    /// typing, not fullscreen, not while hoot is answering). Returns whether
    /// it was shown.
    @discardableResult
    func postNudgeIfAllowed(_ nudge: HootNudge) -> Bool {
        if let refusalReason = reasonNudgeCannotShowNow() {
            print("🦉 nudge (\(nudge.kind.rawValue)) held back: \(refusalReason)")
            return false
        }
        show(nudge)
        return true
    }

    /// Like `postNudgeIfAllowed`, but when the nudge can't show yet it waits
    /// and retries until the rules allow it, for up to `givingUpAfterSeconds`.
    func postNudgeWhenAllowed(_ nudge: HootNudge, givingUpAfterSeconds: TimeInterval) {
        guard areNudgesEnabled else { return }
        if postNudgeIfAllowed(nudge) { return }
        pendingNudges.append(PendingNudge(nudge: nudge, expiryDate: Date().addingTimeInterval(givingUpAfterSeconds)))
        startPendingNudgeRetriesIfNeeded()
    }

    /// nil when a nudge may show right now, otherwise why not (for the log).
    func reasonNudgeCannotShowNow() -> String? {
        let now = Date()
        if !areNudgesEnabled { return "nudges are off" }
        if areNudgesPausedRightNow { return "paused after ignored nudges" }
        if currentNudge != nil { return "another nudge is showing" }
        if let lastNudgeShownDate {
            let minimumGap = isReviewDemoModeOn ? minimumSecondsBetweenNudgesInDemoMode : minimumSecondsBetweenNudges
            if now.timeIntervalSince(lastNudgeShownDate) < minimumGap { return "one nudge per \(Int(minimumGap / 60)) min" }
        }
        if now.timeIntervalSince(lastKeyDownDate) < quietSecondsAfterTypingBeforeNudging { return "the learner is typing" }
        if isHootBusy { return "hoot is answering" }
        if isFrontmostAppFullscreen { return "a fullscreen app is in front" }
        return nil
    }

    // MARK: - Dismissing

    func dismissCurrentNudge(wasIgnored: Bool) {
        guard let dismissedNudge = currentNudge else { return }
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        shownNudgeWatchTimer?.invalidate()
        shownNudgeWatchTimer = nil
        isPointerOverCurrentNudge = false
        currentNudge = nil
        CornerNudgePresenter.shared.dismiss(nudgeId: dismissedNudge.id)

        if wasIgnored {
            consecutiveIgnoredNudgeCount += 1
            if consecutiveIgnoredNudgeCount >= ignoredNudgesInARowThatPauseNudges {
                pauseNudgesAfterBeingIgnored()
            }
        }
        // Whatever was waiting may be allowed after the gap; keep retrying.
        startPendingNudgeRetriesIfNeeded()
    }

    /// The bubble's primary button.
    func performPrimaryActionOfCurrentNudge() {
        guard let clickedNudge = currentNudge else { return }
        consecutiveIgnoredNudgeCount = 0
        dismissCurrentNudge(wasIgnored: false)
        clickedNudge.primaryAction()
    }

    /// The bubble's secondary button ("later", "got it"): an answer, not an ignore.
    func performSecondaryActionOfCurrentNudge() {
        guard let clickedNudge = currentNudge else { return }
        consecutiveIgnoredNudgeCount = 0
        dismissCurrentNudge(wasIgnored: false)
        clickedNudge.secondaryAction()
    }

    /// Lifts an ignore-pause (the settings toggle being switched back on).
    func resumeNudgesNow() {
        nudgesPausedUntilDate = nil
        consecutiveIgnoredNudgeCount = 0
        UserDefaults.standard.removeObject(forKey: Self.pausedUntilDefaultsKey)
    }

    // MARK: - Showing

    private func show(_ nudge: HootNudge) {
        currentNudge = nudge
        lastNudgeShownDate = Date()
        CornerNudgePresenter.shared.present(nudge)

        let fadeSeconds = nudge.kind == .reviewDue ? secondsBeforeAnUntouchedReviewNudgeFades : secondsBeforeAnUntouchedNudgeFades
        scheduleAutoDismiss(ofNudgeWithId: nudge.id, afterSeconds: fadeSeconds)

        shownNudgeWatchTimer?.invalidate()
        shownNudgeWatchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAsideIfTheMomentPassed() }
        }
    }

    private func scheduleAutoDismiss(ofNudgeWithId nudgeId: UUID, afterSeconds seconds: TimeInterval) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentNudge?.id == nudgeId else { return }
                if self.isPointerOverCurrentNudge {
                    // Being read: check again shortly instead of fading.
                    self.scheduleAutoDismiss(ofNudgeWithId: nudgeId, afterSeconds: 2)
                } else {
                    self.dismissCurrentNudge(wasIgnored: true)
                }
            }
        }
    }

    /// hoot started answering, or a fullscreen app came forward: the nudge
    /// leaves quietly (that's not the learner ignoring it).
    private func stepAsideIfTheMomentPassed() {
        guard currentNudge != nil else { return }
        if isHootBusy || isFrontmostAppFullscreen {
            dismissCurrentNudge(wasIgnored: false)
        }
    }

    private func pauseNudgesAfterBeingIgnored() {
        let now = Date()
        let pauseEndDate: Date
        if isReviewDemoModeOn {
            pauseEndDate = now.addingTimeInterval(pauseLengthInDemoMode)
        } else {
            let calendar = Calendar.current
            pauseEndDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
        nudgesPausedUntilDate = pauseEndDate
        consecutiveIgnoredNudgeCount = 0
        UserDefaults.standard.set(pauseEndDate, forKey: Self.pausedUntilDefaultsKey)
        print("🦉 three nudges ignored in a row: nudges paused until \(pauseEndDate)")
    }

    // MARK: - Pending retries

    private func startPendingNudgeRetriesIfNeeded() {
        guard !pendingNudges.isEmpty, pendingNudgeRetryTimer == nil else { return }
        pendingNudgeRetryTimer = Timer.scheduledTimer(withTimeInterval: pendingNudgeRetryIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryPendingNudges() }
        }
    }

    private func retryPendingNudges() {
        let now = Date()
        pendingNudges.removeAll { $0.expiryDate <= now }
        if pendingNudges.isEmpty || !areNudgesEnabled {
            pendingNudges.removeAll()
            pendingNudgeRetryTimer?.invalidate()
            pendingNudgeRetryTimer = nil
            return
        }
        guard reasonNudgeCannotShowNow() == nil else { return }
        let oldestPendingNudge = pendingNudges.removeFirst()
        show(oldestPendingNudge.nudge)
        if pendingNudges.isEmpty {
            pendingNudgeRetryTimer?.invalidate()
            pendingNudgeRetryTimer = nil
        }
    }

    // MARK: - Signals

    /// Listening, thinking, talking or playing an explainer: not a moment to
    /// tap the learner on the shoulder.
    var isHootBusy: Bool {
        guard let hootController else { return false }
        return hootController.voiceState != .idle
            || hootController.isAnswerPipelineRunning
            || hootController.isSpeakingResponseAloud
            || hootController.isExplainerPanelOpen
    }

    private var isFrontmostAppFullscreen: Bool {
        guard let primaryScreenFrame = NSScreen.screens.first?.frame else { return false }
        return FullscreenAppDetector.isFrontmostApplicationFullscreen(onScreenFrame: primaryScreenFrame)
    }

    /// Key presses anywhere (global monitor; needs the accessibility access
    /// push-to-talk already asks for) and in hoot's own windows (local).
    private func startWatchingForTyping() {
        if let globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.lastKeyDownDate = Date() }
        }) {
            keyDownMonitors.append(globalKeyDownMonitor)
        }
        if let localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] keyEvent in
            MainActor.assumeIsolated { self?.lastKeyDownDate = Date() }
            return keyEvent
        }) {
            keyDownMonitors.append(localKeyDownMonitor)
        }
    }
}
