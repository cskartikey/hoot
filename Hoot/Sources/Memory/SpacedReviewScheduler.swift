//
//  SpacedReviewScheduler.swift
//  Hoot
//
//  Spaced review (docs/MEMORY.md §8). Each concept climbs a ladder of
//  review intervals; when one comes due, hoot asks a short recall question
//  through a corner nudge. "answer" starts a review turn in HootController,
//  which grades the spoken answer with [REVIEW:remembered|shaky|forgot] and
//  reports it to MemoryStore.recordReviewResult.
//
//  Demo mode (launch env HOOT_REVIEW_DEMO=1, or the UserDefaults bool
//  hootReviewDemoMode) runs the ladder in minutes so a review shows up
//  during judging.
//

import Foundation

// MARK: - Ladder

enum SpacedReviewSchedule {
    static let reviewDemoModeDefaultsKey = "hootReviewDemoMode"
    static let reviewDemoModeEnvironmentVariable = "HOOT_REVIEW_DEMO"

    /// Stage 0 → +1 day, 1 → +3 days, 2 → +7 days, 3 → +21 days, then done.
    private static let realIntervalsInSeconds: [TimeInterval] = [1, 3, 7, 21].map { $0 * 24 * 60 * 60 }
    /// The same ladder in minutes, for demos.
    private static let demoIntervalsInSeconds: [TimeInterval] = [2, 5, 10, 20].map { $0 * 60 }

    /// True when the env var is set or the (settings) switch is on. The env
    /// var can't be turned off from settings, on purpose: it's for demos.
    static var isDemoModeEnabled: Bool {
        get {
            if ProcessInfo.processInfo.environment[reviewDemoModeEnvironmentVariable] == "1" { return true }
            return UserDefaults.standard.bool(forKey: reviewDemoModeDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: reviewDemoModeDefaultsKey)
        }
    }

    /// How long after reaching `stage` the next review is due; nil once the
    /// concept is past the end of the ladder.
    static func interval(forStage stage: Int) -> TimeInterval? {
        let ladder = isDemoModeEnabled ? demoIntervalsInSeconds : realIntervalsInSeconds
        guard stage >= 0, stage < ladder.count else { return nil }
        return ladder[stage]
    }

    /// "later" on a review nudge pushes it back this far.
    static var laterPostponementInSeconds: TimeInterval {
        isDemoModeEnabled ? 60 : 60 * 60
    }

    /// How often the scheduler looks for a due review.
    static var checkIntervalInSeconds: TimeInterval {
        isDemoModeEnabled ? 15 : 30
    }
}

// MARK: - Scheduler

@MainActor
final class SpacedReviewScheduler {
    static let shared = SpacedReviewScheduler()

    /// The review currently on screen as a nudge, so holding ⌃⌥ while it's
    /// up can answer it.
    struct OfferedReview {
        let concept: String
        let question: String
        let nudgeId: UUID
    }

    private(set) var currentlyOfferedReview: OfferedReview?
    private var lastLoggedBlockedReason: String?

    private weak var hootController: HootController?
    private var dueReviewCheckTimer: Timer?
    private var reviewQuestionGenerationTask: Task<Void, Never>?

    private init() {}

    func start(hootController: HootController) {
        self.hootController = hootController
        dueReviewCheckTimer?.invalidate()
        let checkInterval = SpacedReviewSchedule.checkIntervalInSeconds
        dueReviewCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this runs on the main actor.
            MainActor.assumeIsolated { self?.offerMostOverdueReviewIfPossible() }
        }
        if SpacedReviewSchedule.isDemoModeEnabled {
            print("🧠 spaced review demo mode: ladder in minutes (2, 5, 10, 20)")
        }
    }

    /// The offered review, if its nudge is still the one on screen.
    func reviewOfferedByVisibleNudge() -> OfferedReview? {
        guard let currentlyOfferedReview,
              NudgeCenter.shared.currentNudge?.id == currentlyOfferedReview.nudgeId else { return nil }
        return currentlyOfferedReview
    }

    // MARK: Checking

    private func offerMostOverdueReviewIfPossible() {
        MemoryStore.shared.pullReviewsIntoDemoWindowIfNeeded()
        guard let hootController,
              hootController.voiceState == .idle,
              !hootController.isAnswerPipelineRunning,
              hootController.activeReviewTurn == nil,
              NudgeCenter.shared.currentNudge == nil,
              reviewQuestionGenerationTask == nil,
              let dueConceptReview = MemoryStore.shared.mostOverdueConceptReview() else { return }

        if let cachedReviewQuestion = dueConceptReview.cachedReviewQuestion {
            postReviewNudge(concept: dueConceptReview.concept, question: cachedReviewQuestion)
            return
        }

        let concept = dueConceptReview.concept
        reviewQuestionGenerationTask = Task { [weak self] in
            let reviewQuestion = await Self.generateReviewQuestion(
                forConcept: concept,
                model: hootController.selectedModel
            )
            guard let self else { return }
            self.reviewQuestionGenerationTask = nil
            guard let reviewQuestion else { return }
            MemoryStore.shared.setCachedReviewQuestion(reviewQuestion, forConcept: concept)
            self.offerMostOverdueReviewIfPossible()
        }
    }

    private func postReviewNudge(concept: String, question: String) {
        let reviewNudge = HootNudge(
            kind: .reviewDue,
            message: "quick check: \(question)",
            emphasizedPhrase: question.lowercased().contains(concept) ? concept : nil,
            primaryButtonTitle: "answer",
            primaryAction: { [weak self] in
                self?.currentlyOfferedReview = nil
                self?.hootController?.beginReviewTurn(concept: concept, question: question)
            },
            secondaryButtonTitle: "later",
            secondaryAction: { [weak self] in
                self?.currentlyOfferedReview = nil
                MemoryStore.shared.postponeReview(
                    forConcept: concept,
                    bySeconds: SpacedReviewSchedule.laterPostponementInSeconds
                )
            }
        )
        if NudgeCenter.shared.postNudgeIfAllowed(reviewNudge) {
            currentlyOfferedReview = OfferedReview(concept: concept, question: question, nudgeId: reviewNudge.id)
            print("🧠 review nudge for \"\(concept)\": \(question)")
        } else {
            // Say why once per reason, so "why don't I see a nudge?" is answerable from the console.
            let blockedReason = NudgeCenter.shared.reasonNudgeCannotShowNow() ?? "not allowed right now"
            if blockedReason != lastLoggedBlockedReason {
                lastLoggedBlockedReason = blockedReason
                print("🧠 review for \"\(concept)\" is due but waiting: \(blockedReason)")
            }
        }
    }

    // MARK: Question

    /// One short, text-only call: a spoken-friendly recall question built
    /// from the concept and what hoot said about it. Falls back to a plain
    /// question if the brain is unreachable, so a review is never lost.
    private static func generateReviewQuestion(forConcept concept: String, model: String) async -> String? {
        let savedEntries = MemoryStore.shared.entries(forConcept: concept).prefix(3)
        guard !savedEntries.isEmpty else { return nil }

        let savedMemoryLines = savedEntries.map { entry in
            "- they asked \"\(entry.question)\"; the answer was \"\(entry.answerSummary)\""
        }.joined(separator: "\n")
        let userPrompt = """
        concept: \(concept)
        what they asked before and what you told them:
        \(savedMemoryLines)
        """

        let llmClient = LLMClient(workerBaseURL: HootController.workerBaseURL, model: model)
        do {
            let responseText = try await llmClient.streamAnswer(
                screenshots: [],
                systemPrompt: HootTutorPrompt.reviewQuestionSystemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            if let cleanedQuestion = cleanedReviewQuestion(from: responseText) {
                return cleanedQuestion
            }
        } catch {
            NSLog("⚠️ hoot review question error: %@", String(describing: error))
        }
        return "what do you remember about \(concept)?"
    }

    /// First line, no tags or quotes, lowercase, ending in "?".
    private static func cleanedReviewQuestion(from responseText: String) -> String? {
        let firstLine = HootResponseTags.speakableText(from: responseText)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        var cleanedQuestion = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .lowercased()
        if cleanedQuestion.lowercased().hasPrefix("quick check:") {
            cleanedQuestion = String(cleanedQuestion.dropFirst("quick check:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard cleanedQuestion.count >= 8, cleanedQuestion.count <= 160 else { return nil }
        if !cleanedQuestion.hasSuffix("?") { cleanedQuestion += "?" }
        return cleanedQuestion
    }
}
