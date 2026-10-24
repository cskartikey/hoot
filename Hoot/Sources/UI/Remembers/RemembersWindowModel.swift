//
//  RemembersWindowModel.swift
//  Hoot
//
//  State and wording for the "what hoot remembers" window
//  (design_handoff_hoot_remembers/README.md): which screen is showing, the
//  search text and its semantic matches, the expanded answer, the video
//  being replayed, and the quiz that's starting. Plus the window's copy
//  rules: review ladder stage, "due now / tomorrow / in 3d", dates.
//

import AppKit
import Combine
import SwiftUI

enum RemembersWindowRoute: Equatable {
    case list
    case conceptDetail(concept: String)
}

/// A concept that matched the search, with the part of its name that
/// matched (for the highlight), if the name itself matched.
struct RemembersConceptSearchMatch: Identifiable {
    var id: String { conceptReview.concept }
    let conceptReview: ConceptReview
    let matchedNameRange: Range<String.Index>?
}

/// A saved question that matched the search: exactly (highlighted) or only
/// by meaning (from Moss / on-device recall, no highlight).
struct RemembersQuestionSearchMatch: Identifiable {
    var id: UUID { memoryEntry.id }
    let memoryEntry: MemoryEntry
    let matchedQuestionRange: Range<String.Index>?
}

@MainActor
final class RemembersWindowModel: ObservableObject {
    @Published var route: RemembersWindowRoute = .list
    /// True while moving list → detail, so the push slides the right way.
    @Published private(set) var isNavigatingForward = true
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSemanticSearch()
        }
    }
    /// Saved questions Moss (or on-device recall) found for `searchText`,
    /// best first. Shown after the exact matches.
    @Published private(set) var semanticallyMatchedEntryIds: [UUID] = []
    @Published var expandedAnswerEntryId: UUID?
    @Published private(set) var replayingEntryId: UUID?
    /// The concept whose "quiz me now" was pressed, from the press until
    /// the review turn ends (the view clears it then).
    @Published var quizConcept: String?
    /// True while the review question is being fetched or generated.
    @Published private(set) var isPreparingQuizQuestion = false
    /// Bumped to ask the search field to take focus (⌘F).
    @Published private(set) var searchFocusRequestCount = 0

    weak var hootController: HootController?

    private var semanticSearchTask: Task<Void, Never>?
    private static let semanticSearchDebounceNanoseconds: UInt64 = 200_000_000

    // MARK: Navigation

    func openConceptDetail(_ concept: String) {
        navigate(to: .conceptDetail(concept: concept), isForward: true)
    }

    func goBackToList() {
        navigate(to: .list, isForward: false)
    }

    /// The outgoing screen keeps the transition it was last drawn with, so
    /// when the direction flips, render the new direction once before moving.
    private func navigate(to newRoute: RemembersWindowRoute, isForward: Bool) {
        expandedAnswerEntryId = nil
        guard isNavigatingForward != isForward else {
            route = newRoute
            return
        }
        isNavigatingForward = isForward
        DispatchQueue.main.async { [weak self] in
            self?.route = newRoute
        }
    }

    func requestSearchFocus() {
        if case .conceptDetail = route { goBackToList() }
        searchFocusRequestCount += 1
    }

    // MARK: Search

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSemanticSearch() {
        semanticSearchTask?.cancel()
        let searchTextWhenTyped = trimmedSearchText
        guard searchTextWhenTyped.count >= RememberedQuestionSemanticSearch.minimumQueryLength else {
            semanticallyMatchedEntryIds = []
            return
        }
        semanticSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.semanticSearchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let relatedEntryIds = await RememberedQuestionSemanticSearch.relatedEntryIds(forSearchText: searchTextWhenTyped)
            guard let self, !Task.isCancelled, self.trimmedSearchText == searchTextWhenTyped else { return }
            self.semanticallyMatchedEntryIds = relatedEntryIds
        }
    }

    /// Concepts whose name or any question contains the search text, plus
    /// the concepts of the semantic matches; in the list's sort order.
    func conceptMatches(in memoryStore: MemoryStore) -> [RemembersConceptSearchMatch] {
        let sortedConceptReviews = Self.sortedForList(memoryStore.conceptReviews)
        let lowercasedQuery = trimmedSearchText.lowercased()
        guard !lowercasedQuery.isEmpty else {
            return sortedConceptReviews.map { RemembersConceptSearchMatch(conceptReview: $0, matchedNameRange: nil) }
        }
        let semanticEntryIds = Set(semanticallyMatchedEntryIds)
        return sortedConceptReviews.compactMap { conceptReview in
            let matchedNameRange = conceptReview.concept.range(of: lowercasedQuery, options: .caseInsensitive)
            if matchedNameRange != nil {
                return RemembersConceptSearchMatch(conceptReview: conceptReview, matchedNameRange: matchedNameRange)
            }
            let conceptEntries = memoryStore.entries(forConcept: conceptReview.concept)
            let hasMatchingQuestion = conceptEntries.contains { conceptEntry in
                conceptEntry.question.range(of: lowercasedQuery, options: .caseInsensitive) != nil
                    || semanticEntryIds.contains(conceptEntry.id)
            }
            return hasMatchingQuestion ? RemembersConceptSearchMatch(conceptReview: conceptReview, matchedNameRange: nil) : nil
        }
    }

    /// Exact matches first (newest first), then semantic-only ones (best first).
    func questionMatches(in memoryStore: MemoryStore) -> [RemembersQuestionSearchMatch] {
        let lowercasedQuery = trimmedSearchText.lowercased()
        guard !lowercasedQuery.isEmpty else { return [] }
        var questionMatches: [RemembersQuestionSearchMatch] = []
        var includedEntryIds = Set<UUID>()
        for memoryEntry in memoryStore.entries {
            guard let matchedQuestionRange = memoryEntry.question.range(of: lowercasedQuery, options: .caseInsensitive) else { continue }
            questionMatches.append(RemembersQuestionSearchMatch(memoryEntry: memoryEntry, matchedQuestionRange: matchedQuestionRange))
            includedEntryIds.insert(memoryEntry.id)
        }
        for semanticEntryId in semanticallyMatchedEntryIds where !includedEntryIds.contains(semanticEntryId) {
            guard let memoryEntry = memoryStore.entry(withId: semanticEntryId) else { continue }
            questionMatches.append(RemembersQuestionSearchMatch(memoryEntry: memoryEntry, matchedQuestionRange: nil))
            includedEntryIds.insert(semanticEntryId)
        }
        return questionMatches
    }

    // MARK: Replay / read answer

    /// Video (still there) → play it in the explainer panel with the pet
    /// presenting. Otherwise → toggle the saved answer inline.
    func replayOrReadAnswer(for memoryEntry: MemoryEntry) {
        if let explainerVideoURLString = memoryEntry.explainerVideoURL,
           Self.isSavedVideoStillPlayable(explainerVideoURLString),
           let explainerPanelManager = ExplainerPanelManager.shared {
            replayingEntryId = memoryEntry.id
            explainerPanelManager.playSavedVideo(url: explainerVideoURLString, title: memoryEntry.question)
            return
        }
        expandedAnswerEntryId = expandedAnswerEntryId == memoryEntry.id ? nil : memoryEntry.id
    }

    func clearReplayingEntry() {
        replayingEntryId = nil
    }

    /// Local files are checked on disk; studio (http) URLs are trusted.
    static func isSavedVideoStillPlayable(_ explainerVideoURLString: String) -> Bool {
        guard let explainerVideoURL = URL(string: explainerVideoURLString) else { return false }
        if explainerVideoURL.isFileURL {
            return FileManager.default.fileExists(atPath: explainerVideoURL.path)
        }
        return true
    }

    // MARK: Quiz me now

    /// Gets (or generates) the concept's review question, then hands it to
    /// hoot, which says it out loud and listens for the answer. The window
    /// stays open; grading moves the ladder and the card updates live.
    func startQuiz(forConcept concept: String) {
        guard let hootController, !isPreparingQuizQuestion else { return }
        quizConcept = concept
        isPreparingQuizQuestion = true
        Task { [weak self] in
            let reviewQuestion = await SpacedReviewScheduler.shared.reviewQuestionForQuizMeNow(
                concept: concept,
                model: hootController.selectedModel
            )
            guard let self else { return }
            self.isPreparingQuizQuestion = false
            guard self.quizConcept == concept else { return }
            hootController.beginReviewTurn(concept: concept, question: reviewQuestion)
            print("🧠 quiz me now: \"\(concept)\": \(reviewQuestion)")
        }
    }

    /// From the press until hoot has asked, heard and graded the answer.
    func isQuizRunning(forConcept concept: String, hootController: HootController) -> Bool {
        guard quizConcept == concept else { return false }
        if isPreparingQuizQuestion { return true }
        return hootController.activeReviewTurn != nil
            || hootController.isAnswerPipelineRunning
            || hootController.voiceState != .idle
    }

    // MARK: - Sorting and wording

    static let ladderStepCount = 4
    static let shortLadderLabels = ["1d", "3d", "7d", "21d"]
    static let longLadderLabels = ["1 day", "3 days", "1 week", "3 weeks"]

    /// 0–3 on the ladder; 4 once learned (no next review).
    static func displayedLadderStage(for conceptReview: ConceptReview) -> Int {
        conceptReview.nextReviewAt == nil ? ladderStepCount : min(max(conceptReview.reviewStage, 0), ladderStepCount - 1)
    }

    static func isDue(_ conceptReview: ConceptReview, now: Date = Date()) -> Bool {
        guard let nextReviewAt = conceptReview.nextReviewAt else { return false }
        return nextReviewAt <= now
    }

    /// Due first (oldest due on top), then by next review, learned last.
    static func sortedForList(_ conceptReviews: [ConceptReview]) -> [ConceptReview] {
        conceptReviews.sorted { firstReview, secondReview in
            switch (firstReview.nextReviewAt, secondReview.nextReviewAt) {
            case let (firstDate?, secondDate?):
                if firstDate != secondDate { return firstDate < secondDate }
                return firstReview.concept < secondReview.concept
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return firstReview.lastAskedAt > secondReview.lastAskedAt
            }
        }
    }

    /// Card copy: "due now", "next · in 4m", "next · tomorrow", "next · in 3d", "learned ✓".
    static func cardNextReviewText(for conceptReview: ConceptReview, now: Date = Date()) -> String {
        guard let nextReviewAt = conceptReview.nextReviewAt else { return "learned ✓" }
        let secondsUntilReview = nextReviewAt.timeIntervalSince(now)
        if secondsUntilReview <= 0 { return "due now" }
        if secondsUntilReview < 60 * 60 {
            return "next · in \(max(Int((secondsUntilReview / 60).rounded(.up)), 1))m"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(nextReviewAt) {
            return "next · in \(Int((secondsUntilReview / 3600).rounded(.up)))h"
        }
        if calendar.isDateInTomorrow(nextReviewAt) { return "next · tomorrow" }
        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: nextReviewAt)
        ).day ?? Int((secondsUntilReview / 86_400).rounded(.up))
        return "next · in \(max(dayCount, 1))d"
    }

    /// Detail copy: "due now", "in 4m", "today, 18:30", "tomorrow, 9:00", "sun, oct 26", "none, learned".
    static func detailNextReviewText(for conceptReview: ConceptReview, now: Date = Date()) -> String {
        guard let nextReviewAt = conceptReview.nextReviewAt else { return "none, learned" }
        let secondsUntilReview = nextReviewAt.timeIntervalSince(now)
        if secondsUntilReview <= 0 { return "due now" }
        if secondsUntilReview < 60 * 60 {
            return "in \(max(Int((secondsUntilReview / 60).rounded(.up)), 1))m"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(nextReviewAt) { return "today, \(formatted(nextReviewAt, pattern: "H:mm"))" }
        if calendar.isDateInTomorrow(nextReviewAt) { return "tomorrow, \(formatted(nextReviewAt, pattern: "H:mm"))" }
        return formatted(nextReviewAt, pattern: "EEE, MMM d")
    }

    static func resultText(for reviewResult: ReviewResult?) -> String {
        reviewResult?.rawValue ?? "not checked yet"
    }

    /// "oct 22"
    static func shortDateText(_ date: Date) -> String {
        formatted(date, pattern: "MMM d")
    }

    /// "6:52" or "1:02:14" from a YouTube time in seconds.
    static func youTubeTimestampText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let wholeSeconds = Int(seconds)
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    static func sourceTitleText(for memoryEntry: MemoryEntry) -> String {
        let trimmedSourceTitle = memoryEntry.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedSourceTitle.isEmpty ? "on screen" : trimmedSourceTitle.lowercased()
    }

    static func sourceSymbolName(for memoryEntry: MemoryEntry) -> String {
        memoryEntry.youTubeVideoId != nil ? "play.rectangle.fill" : "doc.text"
    }

    static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func formatted(_ date: Date, pattern: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = pattern
        return dateFormatter.string(from: date).lowercased()
    }
}
