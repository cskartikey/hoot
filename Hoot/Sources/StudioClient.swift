//
//  StudioClient.swift
//  Hoot
//
//  Client for the local "studio" service that turns a tutor answer into a
//  narrated Manim explainer video. Starts a job with POST /explain and then
//  streams progress from GET /jobs/:id/events (Server-Sent Events) as a typed
//  AsyncThrowingStream so the explainer panel can render each stage live.
//
//  The studio runs on localhost, which App Transport Security exempts, so
//  plain http is fine here.
//

import Foundation

// MARK: - Request payload

/// Body of POST /explain. Matches the contract in PLAN.md §5.
nonisolated struct StudioExplainRequestBody: Encodable {
    let question: String
    let brief: String
    let spokenAnswer: String
    let context: StudioExplainContext
    let memory: [StudioMemoryEntry]
    /// "cartesia" or "elevenlabs": the narration provider picked in settings,
    /// so the explainer video speaks with the same voice provider as hoot.
    /// Omitted (nil) lets the studio fall back to its own STUDIO_TTS_PROVIDER.
    var ttsProvider: String? = nil
}

nonisolated struct StudioExplainContext: Encodable {
    var app: String?
    var youtube: StudioYouTubeContext?
    var screenText: String?
}

nonisolated struct StudioYouTubeContext: Encodable, Equatable {
    let videoId: String
    let title: String
    let t: Double
    let transcriptWindow: String
}

nonisolated struct StudioMemoryEntry: Encodable {
    let concept: String
    let summary: String
}

nonisolated private struct StudioExplainResponseBody: Decodable {
    let jobId: String
}

// MARK: - Event payloads

nonisolated struct StudioStageUpdate: Decodable, Equatable {
    let stage: String
    let label: String
    let attempt: Int?
}

nonisolated struct StudioScriptBeat: Decodable, Equatable {
    let narration: String
    let visual: String
}

nonisolated struct StudioScript: Decodable, Equatable {
    /// Short title the studio gives the video (≤60 chars). Optional so an
    /// older studio that only sends beats still decodes.
    let title: String?
    let beats: [StudioScriptBeat]
}

nonisolated struct StudioCaption: Decodable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

nonisolated struct StudioFinishedVideo: Decodable, Equatable {
    let url: String
    let duration: Double
    let captions: [StudioCaption]
    let fallback: Bool
}

nonisolated private struct StudioErrorPayload: Decodable {
    let message: String
}

/// One typed event from the studio job's SSE stream.
nonisolated enum StudioJobEvent: Equatable {
    case stage(StudioStageUpdate)
    case script(StudioScript)
    case done(StudioFinishedVideo)
    case error(message: String)
}

nonisolated enum StudioClientError: LocalizedError {
    case unexpectedHTTPStatus(statusCode: Int, responseBodyText: String)
    case streamEndedBeforeJobFinished

    var errorDescription: String? {
        switch self {
        case .unexpectedHTTPStatus(let statusCode, let responseBodyText):
            return "Studio returned HTTP \(statusCode): \(responseBodyText)"
        case .streamEndedBeforeJobFinished:
            return "Studio closed the event stream before the video finished."
        }
    }
}

// MARK: - Client

final class StudioClient {
    /// Base URL of the studio service. Overridable with the STUDIO_BASE_URL
    /// environment variable so the app can point at another machine at the venue.
    let studioBaseURL: URL

    /// SSE connections stay open for the whole render (~40s+), so requests
    /// and resources get generous timeouts instead of URLSession's defaults.
    private let longLivedURLSession: URLSession

    init(studioBaseURL: URL = StudioClient.defaultStudioBaseURL()) {
        self.studioBaseURL = studioBaseURL

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 300
        sessionConfiguration.timeoutIntervalForResource = 600
        self.longLivedURLSession = URLSession(configuration: sessionConfiguration)
    }

    static func defaultStudioBaseURL() -> URL {
        if let studioBaseURLFromEnvironment = ProcessInfo.processInfo.environment["STUDIO_BASE_URL"],
           let parsedStudioBaseURL = URL(string: studioBaseURLFromEnvironment) {
            return parsedStudioBaseURL
        }
        return URL(string: "http://localhost:7777")!
    }

    /// POST /explain → jobId.
    func startExplainerJob(explainRequestBody: StudioExplainRequestBody) async throws -> String {
        var urlRequest = URLRequest(url: studioBaseURL.appendingPathComponent("explain"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(explainRequestBody)

        let (responseData, urlResponse) = try await longLivedURLSession.data(for: urlRequest)
        try Self.throwIfNotSuccessfulHTTPStatus(urlResponse: urlResponse, responseBodyData: responseData)

        let explainResponseBody = try JSONDecoder().decode(StudioExplainResponseBody.self, from: responseData)
        return explainResponseBody.jobId
    }

    /// GET /jobs/:id/events, parsed into typed events. The stream finishes
    /// after a `done` or `error` event; it throws if the connection drops
    /// before either arrives. Cancelling the consuming task cancels the request.
    func streamJobEvents(jobId: String) -> AsyncThrowingStream<StudioJobEvent, Error> {
        let jobEventsURL = studioBaseURL
            .appendingPathComponent("jobs")
            .appendingPathComponent(jobId)
            .appendingPathComponent("events")
        let longLivedURLSession = self.longLivedURLSession

        return AsyncThrowingStream { continuation in
            let streamingTask = Task {
                do {
                    var urlRequest = URLRequest(url: jobEventsURL)
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (responseByteStream, urlResponse) = try await longLivedURLSession.bytes(for: urlRequest)
                    try Self.throwIfNotSuccessfulHTTPStatus(urlResponse: urlResponse, responseBodyData: Data())

                    // SSE framing: lines of `event: name` and `data: payload`,
                    // with a blank line marking the end of each event.
                    var currentEventName = "message"
                    var currentEventDataLines: [String] = []
                    var didReceiveTerminalEvent = false

                    func dispatchAccumulatedEvent() throws {
                        defer {
                            currentEventName = "message"
                            currentEventDataLines = []
                        }
                        guard !currentEventDataLines.isEmpty else { return }
                        let eventDataText = currentEventDataLines.joined(separator: "\n")
                        guard let parsedJobEvent = try Self.parseJobEvent(
                            eventName: currentEventName,
                            eventDataText: eventDataText
                        ) else { return }

                        continuation.yield(parsedJobEvent)
                        switch parsedJobEvent {
                        case .done, .error:
                            didReceiveTerminalEvent = true
                        default:
                            break
                        }
                    }

                    // Note: URLSession's `lines` skips empty lines, so a blank-line
                    // event boundary is never seen. We therefore also dispatch the
                    // pending event whenever a new `event:` line starts, and once
                    // more when the stream ends.
                    for try await responseLine in responseByteStream.lines {
                        if responseLine.isEmpty {
                            try dispatchAccumulatedEvent()
                        } else if responseLine.hasPrefix(":") {
                            continue // SSE comment / keep-alive
                        } else if responseLine.hasPrefix("event:") {
                            try dispatchAccumulatedEvent()
                            currentEventName = Self.valueAfterSSEFieldName(in: responseLine, fieldName: "event")
                        } else if responseLine.hasPrefix("data:") {
                            currentEventDataLines.append(Self.valueAfterSSEFieldName(in: responseLine, fieldName: "data"))
                            // The studio sends each data payload as one JSON line, so
                            // dispatch as soon as it parses. This keeps the UI live even
                            // though blank-line boundaries are swallowed by `lines`.
                            if Self.isCompleteJSON(currentEventDataLines.joined(separator: "\n")) {
                                try dispatchAccumulatedEvent()
                            }
                        }
                        if didReceiveTerminalEvent { break }
                    }
                    if !didReceiveTerminalEvent {
                        try dispatchAccumulatedEvent()
                    }

                    if didReceiveTerminalEvent {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: StudioClientError.streamEndedBeforeJobFinished)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                streamingTask.cancel()
            }
        }
    }

    // MARK: - Parsing helpers

    /// Returns nil for unknown event names so newer studio versions can add
    /// events without breaking this client.
    nonisolated private static func parseJobEvent(eventName: String, eventDataText: String) throws -> StudioJobEvent? {
        let eventData = Data(eventDataText.utf8)
        let jsonDecoder = JSONDecoder()
        switch eventName {
        case "stage":
            return .stage(try jsonDecoder.decode(StudioStageUpdate.self, from: eventData))
        case "script":
            return .script(try jsonDecoder.decode(StudioScript.self, from: eventData))
        case "done":
            return .done(try jsonDecoder.decode(StudioFinishedVideo.self, from: eventData))
        case "error":
            let errorPayload = try? jsonDecoder.decode(StudioErrorPayload.self, from: eventData)
            return .error(message: errorPayload?.message ?? eventDataText)
        default:
            return nil
        }
    }

    /// Strips "field:" and the single optional leading space the SSE spec allows.
    nonisolated private static func valueAfterSSEFieldName(in sseLine: String, fieldName: String) -> String {
        var fieldValue = String(sseLine.dropFirst(fieldName.count + 1))
        if fieldValue.hasPrefix(" ") {
            fieldValue.removeFirst()
        }
        return fieldValue
    }

    nonisolated private static func isCompleteJSON(_ candidateJSONText: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(candidateJSONText.utf8), options: [.fragmentsAllowed])) != nil
    }

    nonisolated private static func throwIfNotSuccessfulHTTPStatus(urlResponse: URLResponse, responseBodyData: Data) throws {
        guard let httpURLResponse = urlResponse as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpURLResponse.statusCode) else {
            throw StudioClientError.unexpectedHTTPStatus(
                statusCode: httpURLResponse.statusCode,
                responseBodyText: String(data: responseBodyData, encoding: .utf8) ?? ""
            )
        }
    }
}
