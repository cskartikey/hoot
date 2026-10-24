//
//  TextEmbedder.swift
//  Hoot
//
//  Turns text into a vector for semantic recall. The default runs on the
//  Mac (Apple's NaturalLanguage sentence embedding): private, free, no
//  network. A worker-backed embedder (for example OpenAI
//  text-embedding-3-small behind /embed) can be swapped in by conforming to
//  TextEmbedder and assigning MemoryRecall.textEmbedder.
//

import Foundation
import NaturalLanguage

protocol TextEmbedder {
    /// Nil when the embedder is unavailable or the text can't be embedded.
    func embeddingVector(forText text: String) -> [Float]?
}

/// NLEmbedding.sentenceEmbedding(for: .english), loaded on first use.
/// Measured on technical questions it ranks related pairs only loosely
/// (cosine ~0.55–0.65 for the same idea, ~0.45–0.65 for unrelated ones), so
/// MemoryRecall blends it with concept and word overlap.
final class OnDeviceSentenceEmbedder: TextEmbedder {
    private var hasTriedLoadingSentenceEmbedding = false
    private var sentenceEmbedding: NLEmbedding?

    func embeddingVector(forText text: String) -> [Float]? {
        if !hasTriedLoadingSentenceEmbedding {
            hasTriedLoadingSentenceEmbedding = true
            sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
            if sentenceEmbedding == nil {
                NSLog("⚠️ hoot: no on-device sentence embedding for English; recall uses word overlap only")
            }
        }
        guard let sentenceEmbedding else { return nil }
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty,
              let embeddingDoubles = sentenceEmbedding.vector(for: normalizedText) else { return nil }
        return embeddingDoubles.map { Float($0) }
    }
}

enum VectorMath {
    /// Cosine similarity, or nil when the vectors can't be compared.
    static func cosineSimilarity(_ firstVector: [Float], _ secondVector: [Float]) -> Float? {
        guard !firstVector.isEmpty, firstVector.count == secondVector.count else { return nil }
        var dotProduct: Float = 0
        var firstSquaredLength: Float = 0
        var secondSquaredLength: Float = 0
        for componentIndex in firstVector.indices {
            dotProduct += firstVector[componentIndex] * secondVector[componentIndex]
            firstSquaredLength += firstVector[componentIndex] * firstVector[componentIndex]
            secondSquaredLength += secondVector[componentIndex] * secondVector[componentIndex]
        }
        let lengthProduct = firstSquaredLength.squareRoot() * secondSquaredLength.squareRoot()
        guard lengthProduct > 0 else { return nil }
        return dotProduct / lengthProduct
    }
}
