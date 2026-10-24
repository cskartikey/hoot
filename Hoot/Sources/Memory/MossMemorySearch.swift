//
//  MossMemorySearch.swift
//  Hoot
//
//  Talks to the studio's Moss-backed memory search (studio/src/memory/moss.ts
//  on http://localhost:7777). Moss (moss.dev) embeds each memory with its
//  moss-mediumlm model and answers queries from an in-memory session in a few
//  milliseconds, which ranks technical questions far better than Apple's
//  on-device sentence embedding (numbers in studio/README.md, "Moss").
//
//  Everything here is optional: when the studio isn't running or has no Moss
//  credentials, `relatedMemoryHits` returns nil and MemoryRecall falls back
//  to its on-device blend. Writes are fire-and-forget; memory.json stays the
//  source of truth, and a launch-time backfill re-sends anything Moss lacks.
//

import Foundation

struct MossMemoryHit: Decodable, Equatable {
    let id: String
    /// Moss's relevance score, 0…1 (semantic similarity rescaled per model).
    let score: Float
}

@MainActor
final class MossMemorySearch {
    static let shared = MossMemorySearch()

    private let studioBaseURL = URL(string: "http://localhost:7777")!
    /// Recall sits on the path to the spoken answer, so a slow or missing
    /// studio must cost at most this much before the on-device blend runs.
    private let queryTimeoutSeconds: TimeInterval = 0.4
    private let writeTimeoutSeconds: TimeInterval = 15
    /// After the studio fails to answer (or says Moss is off), skip it for a
    /// while instead of paying the timeout on every question.
    private let secondsToSkipAfterUnavailable: TimeInterval = 30
    private var lastUnavailableDate: Date?

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: Indexed text

    /// What Moss indexes for a memory: "concept — question — answer summary".
    /// (The on-device embedding leaves the summary out because it diluted
    /// the vector; Moss's model holds up with it, and its keyword half gets
    /// the extra words.)
    static func indexedText(for entry: MemoryEntry) -> String {
        [entry.concept, entry.question, entry.answerSummary]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private static func documentPayload(for entry: MemoryEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "text": indexedText(for: entry),
            "metadata": [
                "concept": entry.concept,
                "askedAt": ISO8601DateFormatter().string(from: entry.askedAt),
            ],
        ]
    }

    // MARK: Query

    /// Moss's best matches for the query lines (each line is searched on its
    /// own; a memory keeps its best score), best first. Nil when Moss can't
    /// answer right now, so the caller should fall back.
    func relatedMemoryHits(forQueryLines queryLines: [String], topK: Int = 5) async -> [MossMemoryHit]? {
        if let lastUnavailableDate, Date().timeIntervalSince(lastUnavailableDate) < secondsToSkipAfterUnavailable {
            return nil
        }
        guard !queryLines.isEmpty else { return [] }

        struct QueryResponse: Decodable {
            let enabled: Bool
            let ready: Bool?
            let results: [MossMemoryHit]
        }
        let requestBody: [String: Any] = ["texts": queryLines, "topK": topK]
        guard let responseData = await postJSON(path: "/memory/query", body: requestBody, timeoutSeconds: queryTimeoutSeconds),
              let queryResponse = try? JSONDecoder().decode(QueryResponse.self, from: responseData) else {
            lastUnavailableDate = Date()
            return nil
        }
        guard queryResponse.enabled else {
            lastUnavailableDate = Date()
            return nil
        }
        // Enabled but the session is still opening: fall back this once.
        guard queryResponse.ready != false else { return nil }
        return queryResponse.results
    }

    // MARK: Writes (fire-and-forget)

    func upsertInBackground(_ entry: MemoryEntry) {
        let requestBody = Self.documentPayload(for: entry)
        Task { [weak self] in
            guard let self else { return }
            if await self.postJSON(path: "/memory/upsert", body: requestBody, timeoutSeconds: self.writeTimeoutSeconds) == nil {
                // Not fatal: the next launch's backfill sends it.
                print("🧠 moss: upsert didn't reach the studio; the next backfill will send it")
            }
        }
    }

    func resetInBackground() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.postJSON(path: "/memory/reset", body: [:], timeoutSeconds: self.writeTimeoutSeconds)
        }
    }

    /// On launch: if Moss is on and holds fewer memories than memory.json,
    /// send them all (upserts by id, so re-sending is harmless). Retries a
    /// few times while the studio is starting or its Moss session is opening.
    func backfillIfNeeded() async {
        struct HealthResponse: Decodable {
            let enabled: Bool
            let ready: Bool?
            let documentCount: Int?
        }
        for attemptNumber in 1...6 {
            if attemptNumber > 1 { try? await Task.sleep(for: .seconds(10)) }
            guard let healthData = await getJSON(path: "/memory/health", timeoutSeconds: 5),
                  let health = try? JSONDecoder().decode(HealthResponse.self, from: healthData) else { continue }
            guard health.enabled else { return }
            guard health.ready == true, let mossDocumentCount = health.documentCount else { continue }

            let allEntries = MemoryStore.shared.entries
            guard mossDocumentCount < allEntries.count else { return }
            let requestBody: [String: Any] = ["documents": allEntries.map { Self.documentPayload(for: $0) }]
            if await postJSON(path: "/memory/upsert", body: requestBody, timeoutSeconds: 60) != nil {
                print("🧠 moss: backfilled \(allEntries.count) memories (Moss had \(mossDocumentCount))")
                return
            }
        }
    }

    // MARK: HTTP

    private func postJSON(path: String, body: [String: Any], timeoutSeconds: TimeInterval) async -> Data? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var urlRequest = URLRequest(url: studioBaseURL.appendingPathComponent(path), timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData
        return await responseData(for: urlRequest)
    }

    private func getJSON(path: String, timeoutSeconds: TimeInterval) async -> Data? {
        await responseData(for: URLRequest(url: studioBaseURL.appendingPathComponent(path), timeoutInterval: timeoutSeconds))
    }

    private func responseData(for urlRequest: URLRequest) async -> Data? {
        do {
            let (data, urlResponse) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
