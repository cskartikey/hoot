//
//  MemoryRecall.swift
//  Hoot
//
//  Finds past memories related to what the learner is asking now, and
//  writes the "things this learner got stuck on before" block for the tutor.
//
//  Relevance is a blend, because Apple's on-device sentence embedding alone
//  can't tell technical topics apart (tested: "what does det 0 mean for a 3d
//  transformation" scored 0.63 against the determinant memory but 0.71
//  against a variance one). The blend:
//    0.6 × best cosine between any query line and "concept — question"
//  + 0.4 × share of a query line's content words found in the memory
//  + 0.3 × share of the concept's words named in the query ("det" counts
//          for "determinants")
//  clamped to 1. The tutor makes the final call on whether a match is
//  really the same idea, so the threshold leans permissive.
//
//  When the studio's Moss search is up (MossMemorySearch), recall asks Moss
//  first and uses its scores instead; the blend above is the fallback.
//

import Foundation

@MainActor
enum MemoryRecall {
    /// Swap for a network embedder if on-device quality is too weak.
    static var textEmbedder: TextEmbedder = OnDeviceSentenceEmbedder()

    /// Picked from the threshold test: related pairs scored 0.54–1.0 (two
    /// harder paraphrases 0.43–0.45), unrelated ones at most 0.44.
    nonisolated static let defaultMinimumSimilarity: Float = 0.50

    /// Moss score a memory needs to count as related (moss-minilm, picked
    /// with studio/test/moss-memory.ts; see studio/README.md "Moss").
    nonisolated static let minimumMossScore: Float = 0.40
    /// Stricter Moss score for the unprompted "same idea as before" nudge.
    nonisolated static let minimumMossScoreForSameIdeaNudge: Float = 0.55

    private static let embeddingWeight: Float = 0.6
    private static let wordOverlapWeight: Float = 0.4
    private static let conceptMentionWeight: Float = 0.3
    /// Only this many query lines are embedded (question, title, transcript tail).
    private static let maximumQueryLinesEmbedded = 6

    // MARK: Indexing

    /// The text an entry's embedding is computed from. The answer summary is
    /// left out on purpose: in testing, adding it dragged the same-idea
    /// similarity from 0.63 down to 0.37. It still counts in word overlap.
    static func indexedText(concept: String, question: String) -> String {
        "\(concept) — \(question)"
    }

    static func embeddingVector(forText text: String) -> [Float]? {
        textEmbedder.embeddingVector(forText: text)
    }

    // MARK: Search

    /// Splits the query into its non-empty lines (question, video title,
    /// transcript lines), at most `maximumQueryLinesEmbedded`.
    private static func queryLines(in queryText: String) -> [String] {
        queryText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Like `relatedMemories`, but asks Moss first (via the studio) and only
    /// runs the on-device blend when Moss can't answer. Moss scores are
    /// compared with `minimumMossScore`, blend scores with `minimumSimilarity`.
    static func relatedMemoriesPreferringMoss(
        forQueryText queryText: String,
        limit: Int = 3,
        minimumMossScore: Float = MemoryRecall.minimumMossScore,
        minimumSimilarity: Float = MemoryRecall.defaultMinimumSimilarity
    ) async -> [MemoryMatch] {
        let allEntries = MemoryStore.shared.entries
        let lines = Array(queryLines(in: queryText).prefix(maximumQueryLinesEmbedded))
        guard !allEntries.isEmpty, limit > 0, !lines.isEmpty else { return [] }

        guard let mossHits = await MossMemorySearch.shared.relatedMemoryHits(forQueryLines: lines, topK: max(limit * 2, 5)) else {
            let onDeviceMatches = relatedMemories(forQueryText: queryText, limit: limit, minimumSimilarity: minimumSimilarity)
            print("🧠 recall: on-device blend (Moss unavailable), \(onDeviceMatches.count) match(es)")
            return onDeviceMatches
        }

        // Moss may know memories that memory.json has since dropped (the
        // 500-entry cap, or a forget that hasn't reached Moss): skip those.
        let entriesById = Dictionary(allEntries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var bestMatchByConcept: [String: MemoryMatch] = [:]
        for mossHit in mossHits where mossHit.score >= minimumMossScore {
            guard let entry = entriesById[mossHit.id] else { continue }
            if let existingMatch = bestMatchByConcept[entry.concept], existingMatch.similarity >= mossHit.score { continue }
            bestMatchByConcept[entry.concept] = MemoryMatch(entry: entry, similarity: mossHit.score)
        }
        let mossMatches = bestMatchByConcept.values
            .sorted { firstMatch, secondMatch in
                if firstMatch.similarity != secondMatch.similarity { return firstMatch.similarity > secondMatch.similarity }
                return firstMatch.entry.askedAt > secondMatch.entry.askedAt
            }
            .prefix(limit)
            .map { $0 }
        let topScores = mossHits.prefix(3).map { String(format: "%.2f", $0.score) }.joined(separator: ", ")
        print("🧠 recall: Moss, \(mossMatches.count) match(es) ≥ \(minimumMossScore) (top scores: \(topScores))")
        return mossMatches
    }

    /// Past memories related to `queryText`, most similar first, above
    /// `minimumSimilarity`, at most one per concept. `queryText` may span
    /// several lines (question, video title, transcript lines); each line is
    /// compared separately so a long transcript doesn't drown the question.
    static func relatedMemories(
        forQueryText queryText: String,
        limit: Int = 3,
        minimumSimilarity: Float = MemoryRecall.defaultMinimumSimilarity
    ) -> [MemoryMatch] {
        let allEntries = MemoryStore.shared.entries
        guard !allEntries.isEmpty, limit > 0 else { return [] }

        let queryLines = queryLines(in: queryText)
        guard !queryLines.isEmpty else { return [] }

        let queryLineEmbeddings = queryLines.prefix(maximumQueryLinesEmbedded).compactMap { embeddingVector(forText: $0) }
        let queryLineWords = queryLines.map { contentWords(in: $0) }
        let allQueryWords = queryLineWords.flatMap { $0 }

        var bestMatchByConcept: [String: MemoryMatch] = [:]
        for entry in allEntries {
            let relevance = relevanceScore(
                of: entry,
                queryLineEmbeddings: queryLineEmbeddings,
                queryLineWords: queryLineWords,
                allQueryWords: allQueryWords
            )
            guard relevance >= minimumSimilarity else { continue }
            if let existingMatch = bestMatchByConcept[entry.concept], existingMatch.similarity >= relevance { continue }
            bestMatchByConcept[entry.concept] = MemoryMatch(entry: entry, similarity: relevance)
        }

        return bestMatchByConcept.values
            .sorted { firstMatch, secondMatch in
                if firstMatch.similarity != secondMatch.similarity { return firstMatch.similarity > secondMatch.similarity }
                return firstMatch.entry.askedAt > secondMatch.entry.askedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func relevanceScore(
        of entry: MemoryEntry,
        queryLineEmbeddings: [[Float]],
        queryLineWords: [[String]],
        allQueryWords: [String]
    ) -> Float {
        let entryWords = contentWords(in: entry.question + " " + entry.answerSummary + " " + entry.concept)
        let bestWordOverlap = queryLineWords
            .filter { !$0.isEmpty }
            .map { lineWords -> Float in
                let overlappingWordCount = lineWords.filter { queryWord in
                    entryWords.contains { isSameWord($0, queryWord) }
                }.count
                return Float(overlappingWordCount) / Float(lineWords.count)
            }
            .max() ?? 0

        let bestCosine = queryLineEmbeddings
            .compactMap { VectorMath.cosineSimilarity($0, entry.embedding) }
            .max()
        // Without embeddings (no on-device model, or an old entry), word
        // overlap stands in so recall still works on clear matches.
        let embeddingTerm = max(bestCosine ?? bestWordOverlap, 0)

        let conceptWords = contentWords(in: entry.concept)
        let conceptMentionShare: Float
        if conceptWords.isEmpty {
            conceptMentionShare = 0
        } else {
            let mentionedConceptWordCount = conceptWords.filter { conceptWord in
                allQueryWords.contains { isConceptWord(conceptWord, mentionedAs: $0) }
            }.count
            conceptMentionShare = Float(mentionedConceptWordCount) / Float(conceptWords.count)
        }

        let blendedScore = embeddingWeight * embeddingTerm
            + wordOverlapWeight * bestWordOverlap
            + conceptMentionWeight * conceptMentionShare
        return min(blendedScore, 1)
    }

    // MARK: Prompt block

    /// The "things this learner got stuck on before" block for the tutor
    /// prompt, or nil when nothing relevant passes the threshold. Moss first,
    /// on-device blend when the studio can't answer.
    static func promptContextBlock(forQueryText queryText: String) async -> String? {
        let relatedMatches = await relatedMemoriesPreferringMoss(forQueryText: queryText)
        guard !relatedMatches.isEmpty else { return nil }

        let now = Date()
        var promptLines = ["things this learner got stuck on before (most related first):"]
        for relatedMatch in relatedMatches {
            let entry = relatedMatch.entry
            let conceptReview = MemoryStore.shared.conceptReview(forConcept: entry.concept)
            let timesAsked = max(conceptReview?.timesAsked ?? 1, 1)
            let lastAskedDescription = relativeDayDescription(for: conceptReview?.lastAskedAt ?? entry.askedAt, now: now)
            let askedDescription = timesAsked == 1
                ? "once, \(lastAskedDescription)"
                : "asked \(timesAsked)×, last \(lastAskedDescription)"
            var memoryLine = "- \(entry.concept) (\(askedDescription)): they asked \"\(shortened(entry.question, toAtMost: 140))\""
            if !entry.answerSummary.isEmpty {
                memoryLine += "; you said \"\(shortened(entry.answerSummary, toAtMost: 240))\""
            }
            if MemoryStore.shared.mostRecentEntryWithExplainerVideo(forConcept: entry.concept) != nil {
                memoryLine += " (you made them an animation of it)"
            }
            promptLines.append(memoryLine)
        }
        return promptLines.joined(separator: "\n")
    }

    /// "earlier today", "yesterday", "tuesday" (within the week), else "oct 12".
    static func relativeDayDescription(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "earlier today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfToday = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = (0..<7).contains(daysAgo) ? "EEEE" : "MMM d"
        return dateFormatter.string(from: date).lowercased()
    }

    private static func shortened(_ text: String, toAtMost maximumLength: Int) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > maximumLength else { return trimmedText }
        return String(trimmedText.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Words

    /// Words that carry no topic, so "what does X mean" doesn't match every
    /// "what does Y mean".
    private static let wordsWithoutTopic: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "what", "why", "how", "does", "do",
        "did", "doing", "mean", "means", "meaning", "when", "where", "which", "who", "whom", "this", "that", "these",
        "those", "it", "its", "of", "in", "on", "for", "to", "and", "or", "but", "with", "by", "from", "as", "at",
        "so", "if", "then", "than", "can", "could", "would", "should", "will", "i", "you", "me", "my", "your", "we",
        "they", "he", "she", "them", "there", "here", "about", "into", "just", "still", "after", "before",
        "actually", "really", "get", "gets", "got", "make", "makes", "like", "some", "any", "all", "every", "one",
        "not", "no", "yes", "whats", "difference", "between", "thing", "things", "work", "works", "wait", "okay",
        "ok", "um", "uh", "hoot", "explain", "again", "same", "kind", "sort", "lot", "very", "much", "more", "most",
        "also", "even", "need", "know", "see", "say", "said", "going", "gonna", "want", "think", "right", "now",
        "doesn't", "don't", "isn't", "it's", "what's", "i'm", "there's", "that's", "let", "let's", "use", "used"
    ]

    static func contentWords(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.count >= 2 && !wordsWithoutTopic.contains($0) }
    }

    /// Exact, or the same first six letters ("transformation" /
    /// "transformations"). Six, not five: "variance" vs "variable".
    private static func isSameWord(_ firstWord: String, _ secondWord: String) -> Bool {
        if firstWord == secondWord { return true }
        return firstWord.count >= 6 && secondWord.count >= 6 && firstWord.prefix(6) == secondWord.prefix(6)
    }

    /// Like isSameWord, plus abbreviations of the concept ("det" for
    /// "determinants", "backprop" for "backpropagation").
    private static func isConceptWord(_ conceptWord: String, mentionedAs queryWord: String) -> Bool {
        if isSameWord(conceptWord, queryWord) { return true }
        if queryWord.count >= 3 && conceptWord.hasPrefix(queryWord) { return true }
        return conceptWord.count >= 4 && queryWord.hasPrefix(conceptWord)
    }
}
