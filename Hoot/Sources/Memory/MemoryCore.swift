//
//  MemoryCore.swift
//  Hoot
//
//  SKELETON — the shared surface of hoot's memory (see docs/MEMORY.md).
//  Owned by the memory core agent (may split into more files in Memory/).
//  The panel and nudge agents build against these names and signatures;
//  keep them, you may add members.
//

import Combine
import Foundation

// MARK: - Data

struct MemoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let askedAt: Date
    let question: String
    /// 1–3 words, lowercase, from the tutor's [CONCEPT:] tag.
    let concept: String
    /// First ~2 sentences of the spoken answer.
    let answerSummary: String
    /// YouTube title or app name.
    let sourceTitle: String?
    let youTubeVideoId: String?
    let youTubeTimeSeconds: Double?
    /// Filled in when the explainer video for this question finishes.
    var explainerVideoURL: String?
    /// Sentence embedding of "concept — question — answerSummary".
    var embedding: [Float]
}

enum ReviewResult: String, Codable {
    case remembered
    case shaky
    case forgot
}

struct ConceptReview: Codable, Identifiable, Equatable {
    var id: String { concept }
    let concept: String
    var timesAsked: Int
    var lastAskedAt: Date
    /// 0,1,2,3… → interval ladder (1d, 3d, 7d, 21d; minutes in demo mode).
    var reviewStage: Int
    var nextReviewAt: Date?
    var lastReviewResult: ReviewResult?
    /// Generated lazily when the review comes due.
    var cachedReviewQuestion: String?
}

struct MemoryMatch: Equatable {
    let entry: MemoryEntry
    let similarity: Float
}

// MARK: - Store

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// Newest first.
    @Published private(set) var entries: [MemoryEntry] = []
    @Published private(set) var conceptReviews: [ConceptReview] = []

    /// Saves a new memory after an answer. Returns the new entry's id.
    @discardableResult
    func recordAnsweredQuestion(
        question: String,
        concept: String,
        answerSummary: String,
        sourceTitle: String?,
        youTubeVideoId: String?,
        youTubeTimeSeconds: Double?
    ) -> UUID {
        UUID()
    }

    func attachExplainerVideo(url: String, toEntryWithId entryId: UUID) {}

    /// Top concepts by times asked, most recent first on ties.
    func topConcepts(limit: Int) -> [ConceptReview] { [] }

    func entries(forConcept concept: String) -> [MemoryEntry] { [] }

    func recordReviewResult(_ reviewResult: ReviewResult, forConcept concept: String) {}

    /// Deletes everything (memory file included).
    func forgetEverything() {}
}

// MARK: - Recall

@MainActor
enum MemoryRecall {
    /// Past memories related to `queryText`, most similar first, above `minimumSimilarity`.
    static func relatedMemories(forQueryText queryText: String, limit: Int = 3, minimumSimilarity: Float = 0.70) -> [MemoryMatch] {
        []
    }

    /// The "things this learner got stuck on before" block for the tutor prompt,
    /// or nil when nothing relevant passes the threshold.
    static func promptContextBlock(forQueryText queryText: String) -> String? {
        nil
    }
}

