//
//  RemembersMemoryQueries.swift
//  Hoot
//
//  The two memory questions the "what hoot remembers" window asks that the
//  rest of the app doesn't:
//    - "which saved questions are about this search text?" by meaning, not
//      just spelling (Moss through the studio, on-device recall as fallback);
//    - "give me a review question for this concept right now" for
//      "quiz me now", which works whether or not the concept is due.
//

import Foundation

@MainActor
enum RememberedQuestionSemanticSearch {
    /// Shorter queries are all noise to an embedding ("de", "a"); the
    /// window's exact substring match covers them.
    static let minimumQueryLength = 3

    /// Ids of saved questions related to `searchText`, best first. Moss when
    /// the studio can answer (one query line, scores above the recall
    /// threshold); otherwise the on-device blend MemoryRecall uses, which
    /// keeps one entry per concept.
    static func relatedEntryIds(forSearchText searchText: String, limit: Int = 12) async -> [UUID] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearchText.count >= minimumQueryLength, !MemoryStore.shared.entries.isEmpty else { return [] }

        if let mossHits = await MossMemorySearch.shared.relatedMemoryHits(forQueryLines: [trimmedSearchText], topK: limit) {
            let knownEntryIds = Set(MemoryStore.shared.entries.map(\.id))
            return mossHits
                .filter { $0.score >= MemoryRecall.minimumMossScore }
                .compactMap { UUID(uuidString: $0.id) }
                .filter { knownEntryIds.contains($0) }
        }
        return MemoryRecall.relatedMemories(forQueryText: trimmedSearchText, limit: limit)
            .map(\.entry.id)
    }
}

extension SpacedReviewScheduler {
    /// The concept's cached review question, or a freshly generated one
    /// (cached for next time, exactly like a due review). Never nil: if the
    /// brain is unreachable the scheduler's plain fallback question is used.
    func reviewQuestionForQuizMeNow(concept: String, model: String) async -> String {
        if let cachedReviewQuestion = MemoryStore.shared.conceptReview(forConcept: concept)?.cachedReviewQuestion {
            return cachedReviewQuestion
        }
        if let generatedReviewQuestion = await Self.generateReviewQuestion(forConcept: concept, model: model) {
            MemoryStore.shared.setCachedReviewQuestion(generatedReviewQuestion, forConcept: concept)
            return generatedReviewQuestion
        }
        return "what do you remember about \(concept)?"
    }
}
