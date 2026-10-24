//
//  MemoryCore.swift
//  Hoot
//
//  The shared surface of hoot's memory (see docs/MEMORY.md): what the
//  learner got stuck on, one entry per answered question, plus one
//  ConceptReview per concept for spaced review. Everything lives in
//  ~/Library/Application Support/hoot/memory.json and never leaves the Mac.
//
//  Recall (embeddings + the tutor prompt block) is in MemoryRecall.swift,
//  the review ladder and review nudges in SpacedReviewScheduler.swift.
//

import Combine
import Foundation

extension Notification.Name {
    /// Posted after "forget everything", so the tutor drops its conversation
    /// history too and nothing from before survives in memory.
    static let hootMemoryWasForgotten = Notification.Name("hootMemoryWasForgotten")
}

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
    /// Sentence embedding of the entry's indexed text (see
    /// `MemoryRecall.indexedText(concept:question:)`). Empty when no
    /// embedder was available; recall then falls back to word overlap.
    var embedding: [Float]

    init(
        id: UUID,
        askedAt: Date,
        question: String,
        concept: String,
        answerSummary: String,
        sourceTitle: String?,
        youTubeVideoId: String?,
        youTubeTimeSeconds: Double?,
        explainerVideoURL: String?,
        embedding: [Float]
    ) {
        self.id = id
        self.askedAt = askedAt
        self.question = question
        self.concept = concept
        self.answerSummary = answerSummary
        self.sourceTitle = sourceTitle
        self.youTubeVideoId = youTubeVideoId
        self.youTubeTimeSeconds = youTubeTimeSeconds
        self.explainerVideoURL = explainerVideoURL
        self.embedding = embedding
    }

    // The embedding is stored as base64 of its Float32 bytes: 512 floats as
    // JSON numbers would make every entry ~5 KB and the file slow to write.

    private enum CodingKeys: String, CodingKey {
        case id, askedAt, question, concept, answerSummary, sourceTitle
        case youTubeVideoId, youTubeTimeSeconds, explainerVideoURL, embedding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        askedAt = try container.decode(Date.self, forKey: .askedAt)
        question = try container.decode(String.self, forKey: .question)
        concept = try container.decode(String.self, forKey: .concept)
        answerSummary = try container.decodeIfPresent(String.self, forKey: .answerSummary) ?? ""
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        youTubeVideoId = try container.decodeIfPresent(String.self, forKey: .youTubeVideoId)
        youTubeTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .youTubeTimeSeconds)
        explainerVideoURL = try container.decodeIfPresent(String.self, forKey: .explainerVideoURL)
        if let base64Embedding = try? container.decodeIfPresent(String.self, forKey: .embedding),
           let embeddingBytes = Data(base64Encoded: base64Embedding) {
            embedding = Self.floats(fromLittleEndianBytes: embeddingBytes)
        } else {
            embedding = (try? container.decodeIfPresent([Float].self, forKey: .embedding)) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(askedAt, forKey: .askedAt)
        try container.encode(question, forKey: .question)
        try container.encode(concept, forKey: .concept)
        try container.encode(answerSummary, forKey: .answerSummary)
        try container.encodeIfPresent(sourceTitle, forKey: .sourceTitle)
        try container.encodeIfPresent(youTubeVideoId, forKey: .youTubeVideoId)
        try container.encodeIfPresent(youTubeTimeSeconds, forKey: .youTubeTimeSeconds)
        try container.encodeIfPresent(explainerVideoURL, forKey: .explainerVideoURL)
        try container.encode(Self.littleEndianBytes(fromFloats: embedding).base64EncodedString(), forKey: .embedding)
    }

    private static func littleEndianBytes(fromFloats floats: [Float]) -> Data {
        var bytes = Data(capacity: floats.count * 4)
        for floatValue in floats {
            withUnsafeBytes(of: floatValue.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private static func floats(fromLittleEndianBytes bytes: Data) -> [Float] {
        let floatCount = bytes.count / 4
        var floats: [Float] = []
        floats.reserveCapacity(floatCount)
        for floatIndex in 0..<floatCount {
            let byteOffset = bytes.startIndex + floatIndex * 4
            var bitPattern: UInt32 = 0
            for byteIndex in 0..<4 {
                bitPattern |= UInt32(bytes[byteOffset + byteIndex]) << (8 * UInt32(byteIndex))
            }
            floats.append(Float(bitPattern: bitPattern))
        }
        return floats
    }
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
    /// Nil once the concept has climbed past the end of the ladder.
    var nextReviewAt: Date?
    var lastReviewResult: ReviewResult?
    /// Generated lazily when the review comes due.
    var cachedReviewQuestion: String?
}

struct MemoryMatch: Equatable {
    let entry: MemoryEntry
    /// Relevance in 0…1: Moss's score when recall went through Moss, else the
    /// sentence embedding blended with concept and word overlap (see
    /// MemoryRecall). Not a raw cosine.
    let similarity: Float
}

// MARK: - Store

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// Newest first.
    @Published private(set) var entries: [MemoryEntry] = []
    @Published private(set) var conceptReviews: [ConceptReview] = []

    /// Old entries beyond this are dropped; the file stays small enough to
    /// load in full and search by brute force.
    static let maximumEntryCount = 500

    /// The whole file. Versioned so a later format can migrate instead of
    /// throwing everything away.
    private struct MemoryFileContents: Codable {
        var formatVersion = 1
        var entries: [MemoryEntry]
        var conceptReviews: [ConceptReview]
    }

    private let memoryFileURL: URL
    /// File writes happen off the main thread, in order.
    private let fileWriteQueue = DispatchQueue(label: "hoot.memory.file-writes", qos: .utility)

    private init() {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        memoryFileURL = applicationSupportDirectory
            .appendingPathComponent("hoot", isDirectory: true)
            .appendingPathComponent("memory.json")
        loadFromDisk()
        // After init returns (MossMemorySearch reads MemoryStore.shared):
        // make sure Moss has every memory, e.g. ones saved before Moss was set up.
        Task { @MainActor in
            await MossMemorySearch.shared.backfillIfNeeded()
        }
    }

    // MARK: Capture

    /// Saves a new memory after an answer and bumps the concept's review
    /// bookkeeping. Returns the new entry's id.
    @discardableResult
    func recordAnsweredQuestion(
        question: String,
        concept: String,
        answerSummary: String,
        sourceTitle: String?,
        youTubeVideoId: String?,
        youTubeTimeSeconds: Double?
    ) -> UUID {
        let normalizedConcept = Self.normalizedConcept(concept)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let askedAt = Date()

        let newEntry = MemoryEntry(
            id: UUID(),
            askedAt: askedAt,
            question: trimmedQuestion,
            concept: normalizedConcept,
            answerSummary: answerSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceTitle: sourceTitle,
            youTubeVideoId: youTubeVideoId,
            youTubeTimeSeconds: youTubeTimeSeconds,
            explainerVideoURL: nil,
            embedding: MemoryRecall.embeddingVector(
                forText: MemoryRecall.indexedText(concept: normalizedConcept, question: trimmedQuestion)
            ) ?? []
        )

        var updatedEntries = entries
        updatedEntries.insert(newEntry, at: 0)
        if updatedEntries.count > Self.maximumEntryCount {
            updatedEntries.removeLast(updatedEntries.count - Self.maximumEntryCount)
        }
        entries = updatedEntries

        bumpConceptReviewForNewQuestion(concept: normalizedConcept, askedAt: askedAt)
        saveToDisk()
        MossMemorySearch.shared.upsertInBackground(newEntry)
        print("🧠 remembered \"\(normalizedConcept)\" (\(entries.count) memories)")
        return newEntry.id
    }

    /// Demo mode can be switched on after reviews were scheduled on the real
    /// (day-long) ladder. Pull any review that's further out than its demo
    /// interval in to "now + demo interval", so turning demo mode on works
    /// for memories you already have. Returns how many were moved.
    @discardableResult
    func pullReviewsIntoDemoWindowIfNeeded(now: Date = Date()) -> Int {
        guard SpacedReviewSchedule.isDemoModeEnabled else { return 0 }
        var movedCount = 0
        var updatedConceptReviews = conceptReviews
        for reviewIndex in updatedConceptReviews.indices {
            guard let nextReviewAt = updatedConceptReviews[reviewIndex].nextReviewAt,
                  let demoInterval = SpacedReviewSchedule.interval(forStage: updatedConceptReviews[reviewIndex].reviewStage) else { continue }
            let latestDemoReviewDate = now.addingTimeInterval(demoInterval)
            if nextReviewAt > latestDemoReviewDate {
                updatedConceptReviews[reviewIndex].nextReviewAt = latestDemoReviewDate
                movedCount += 1
            }
        }
        guard movedCount > 0 else { return 0 }
        conceptReviews = updatedConceptReviews
        saveToDisk()
        print("🧠 demo mode: pulled \(movedCount) review(s) into the demo window")
        return movedCount
    }

    /// Asking about a concept again means it didn't stick: count it, and
    /// restart its review ladder from the bottom.
    private func bumpConceptReviewForNewQuestion(concept: String, askedAt: Date) {
        let firstReviewDate = SpacedReviewSchedule.interval(forStage: 0).map { askedAt.addingTimeInterval($0) }
        var updatedConceptReviews = conceptReviews
        if let existingIndex = updatedConceptReviews.firstIndex(where: { $0.concept == concept }) {
            updatedConceptReviews[existingIndex].timesAsked += 1
            updatedConceptReviews[existingIndex].lastAskedAt = askedAt
            updatedConceptReviews[existingIndex].reviewStage = 0
            updatedConceptReviews[existingIndex].nextReviewAt = firstReviewDate
            // The new answer may be framed differently; ask a fresh question.
            updatedConceptReviews[existingIndex].cachedReviewQuestion = nil
        } else {
            updatedConceptReviews.append(ConceptReview(
                concept: concept,
                timesAsked: 1,
                lastAskedAt: askedAt,
                reviewStage: 0,
                nextReviewAt: firstReviewDate,
                lastReviewResult: nil,
                cachedReviewQuestion: nil
            ))
        }
        conceptReviews = updatedConceptReviews
    }

    func attachExplainerVideo(url: String, toEntryWithId entryId: UUID) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[entryIndex].explainerVideoURL = url
        saveToDisk()
        print("🧠 saved the explainer video for \"\(entries[entryIndex].concept)\"")
    }

    // MARK: Reading

    func entry(withId entryId: UUID) -> MemoryEntry? {
        entries.first(where: { $0.id == entryId })
    }

    /// Top concepts by times asked, most recent first on ties.
    func topConcepts(limit: Int) -> [ConceptReview] {
        let sortedConceptReviews = conceptReviews.sorted { firstReview, secondReview in
            if firstReview.timesAsked != secondReview.timesAsked {
                return firstReview.timesAsked > secondReview.timesAsked
            }
            return firstReview.lastAskedAt > secondReview.lastAskedAt
        }
        return Array(sortedConceptReviews.prefix(max(limit, 0)))
    }

    /// Newest first.
    func entries(forConcept concept: String) -> [MemoryEntry] {
        let normalizedConcept = Self.normalizedConcept(concept)
        return entries.filter { $0.concept == normalizedConcept }
    }

    func conceptReview(forConcept concept: String) -> ConceptReview? {
        let normalizedConcept = Self.normalizedConcept(concept)
        return conceptReviews.first(where: { $0.concept == normalizedConcept })
    }

    /// The newest saved explainer video for a concept, if any.
    func mostRecentEntryWithExplainerVideo(forConcept concept: String) -> MemoryEntry? {
        entries(forConcept: concept).first(where: { $0.explainerVideoURL != nil })
    }

    /// The due concept whose review date passed longest ago, or nil.
    func mostOverdueConceptReview(asOf now: Date = Date()) -> ConceptReview? {
        conceptReviews
            .filter { conceptReview in
                guard let nextReviewAt = conceptReview.nextReviewAt else { return false }
                return nextReviewAt <= now
            }
            .min { ($0.nextReviewAt ?? now) < ($1.nextReviewAt ?? now) }
    }

    // MARK: Review bookkeeping

    /// remembered → next stage · shaky → same stage, half the interval ·
    /// forgot → back to stage 0.
    func recordReviewResult(_ reviewResult: ReviewResult, forConcept concept: String) {
        let normalizedConcept = Self.normalizedConcept(concept)
        guard let reviewIndex = conceptReviews.firstIndex(where: { $0.concept == normalizedConcept }) else { return }
        let now = Date()
        var conceptReview = conceptReviews[reviewIndex]

        switch reviewResult {
        case .remembered:
            conceptReview.reviewStage += 1
            conceptReview.nextReviewAt = SpacedReviewSchedule.interval(forStage: conceptReview.reviewStage)
                .map { now.addingTimeInterval($0) }
        case .shaky:
            let fullInterval = SpacedReviewSchedule.interval(forStage: conceptReview.reviewStage)
                ?? SpacedReviewSchedule.interval(forStage: 0)
            conceptReview.nextReviewAt = fullInterval.map { now.addingTimeInterval($0 / 2) }
        case .forgot:
            conceptReview.reviewStage = 0
            conceptReview.nextReviewAt = SpacedReviewSchedule.interval(forStage: 0).map { now.addingTimeInterval($0) }
        }
        conceptReview.lastReviewResult = reviewResult
        // Next time, a different question about the same idea.
        conceptReview.cachedReviewQuestion = nil

        conceptReviews[reviewIndex] = conceptReview
        saveToDisk()
        let nextReviewDescription = conceptReview.nextReviewAt.map { "next review \($0)" } ?? "ladder finished"
        print("🧠 review of \"\(normalizedConcept)\": \(reviewResult.rawValue), stage \(conceptReview.reviewStage), \(nextReviewDescription)")
    }

    /// "later" on a review nudge.
    func postponeReview(forConcept concept: String, bySeconds secondsToPostpone: TimeInterval) {
        let normalizedConcept = Self.normalizedConcept(concept)
        guard let reviewIndex = conceptReviews.firstIndex(where: { $0.concept == normalizedConcept }) else { return }
        conceptReviews[reviewIndex].nextReviewAt = Date().addingTimeInterval(secondsToPostpone)
        saveToDisk()
    }

    func setCachedReviewQuestion(_ reviewQuestion: String, forConcept concept: String) {
        let normalizedConcept = Self.normalizedConcept(concept)
        guard let reviewIndex = conceptReviews.firstIndex(where: { $0.concept == normalizedConcept }) else { return }
        conceptReviews[reviewIndex].cachedReviewQuestion = reviewQuestion
        saveToDisk()
    }

    // MARK: Forgetting

    /// Deletes everything (memory file included).
    func forgetEverything() {
        entries = []
        conceptReviews = []
        let memoryFileURL = memoryFileURL
        fileWriteQueue.async {
            try? FileManager.default.removeItem(at: memoryFileURL)
        }
        MossMemorySearch.shared.resetInBackground()
        NotificationCenter.default.post(name: .hootMemoryWasForgotten, object: nil)
        print("🧠 forgot everything")
    }

    // MARK: Concepts

    /// "  Determinants. " → "determinants"; keeps letters, digits, spaces,
    /// hyphens and apostrophes so the same idea always lands on one key.
    static func normalizedConcept(_ rawConcept: String) -> String {
        let allowedCharacters = rawConcept.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber || character == "-" || character == "'") ? character : " "
        }
        return String(allowedCharacters)
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: Persistence

    private func loadFromDisk() {
        guard let fileData = try? Data(contentsOf: memoryFileURL) else { return }
        do {
            let fileContents = try JSONDecoder().decode(MemoryFileContents.self, from: fileData)
            entries = fileContents.entries.sorted { $0.askedAt > $1.askedAt }
            conceptReviews = fileContents.conceptReviews
        } catch {
            // A corrupt file must not take hoot down. Keep a copy for
            // debugging and start fresh.
            NSLog("⚠️ hoot memory file unreadable, starting fresh: %@", String(describing: error))
            let corruptCopyURL = memoryFileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: corruptCopyURL)
            try? FileManager.default.moveItem(at: memoryFileURL, to: corruptCopyURL)
        }
    }

    private func saveToDisk() {
        let fileContents = MemoryFileContents(entries: entries, conceptReviews: conceptReviews)
        let encodedFileData: Data
        do {
            encodedFileData = try JSONEncoder().encode(fileContents)
        } catch {
            NSLog("⚠️ hoot memory encode failed: %@", String(describing: error))
            return
        }
        let memoryFileURL = memoryFileURL
        fileWriteQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: memoryFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try encodedFileData.write(to: memoryFileURL, options: .atomic)
            } catch {
                NSLog("⚠️ hoot memory write failed: %@", String(describing: error))
            }
        }
    }
}
