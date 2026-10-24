//
//  LLMClient.swift
//  Hoot
//

import Foundation

enum LLMClientError: LocalizedError {
    case invalidWorkerURL(String)
    case httpError(statusCode: Int, responseBody: String)
    case streamReportedError(String)
    case noResponseBeforeTimeout(seconds: Int)
    case streamStalled(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .invalidWorkerURL(let workerURLString):
            return "The worker URL \"\(workerURLString)\" isn't a valid URL."
        case .httpError(let statusCode, let responseBody):
            return "The worker answered \(statusCode): \(responseBody)"
        case .streamReportedError(let errorMessage):
            return "The model stopped with an error: \(errorMessage)"
        case .noResponseBeforeTimeout(let seconds):
            return "The worker didn't respond within \(seconds) seconds."
        case .streamStalled(let seconds):
            return "The answer stopped arriving for \(seconds) seconds, so hoot gave up on it."
        }
    }
}

/// Streams an answer from the worker's /chat route (Anthropic Messages
/// format, SSE). The worker may answer with OpenAI behind the scenes.
@MainActor
final class LLMClient {
    struct ConversationTurn {
        let userText: String
        let assistantText: String
    }

    var model: String

    private let workerBaseURL: String
    private let maximumOutputTokens = 1024
    /// How long we wait for the first byte (headers or data) of a response.
    private let secondsToWaitForFirstByte: TimeInterval = 25
    /// Once streaming, how long silence can last before we call the connection dead.
    /// Without this, a half-dead connection once left a question hanging for 62 seconds.
    private let secondsOfSilenceBeforeStreamIsStalled: TimeInterval = 20

    private let urlSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.default
        // Our watchdog enforces the real limits; these are a generous backstop.
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: sessionConfiguration)
    }()

    init(workerBaseURL: String, model: String) {
        // Tolerate a trailing slash so "\(base)/chat" never becomes "//chat".
        var normalizedWorkerBaseURL = workerBaseURL
        while normalizedWorkerBaseURL.hasSuffix("/") { normalizedWorkerBaseURL.removeLast() }
        self.workerBaseURL = normalizedWorkerBaseURL
        self.model = model
    }

    /// Returns the full answer; `onTextChunk` gets the accumulated text as it streams.
    func streamAnswer(
        screenshots: [CapturedScreen],
        systemPrompt: String,
        conversationHistory: [ConversationTurn],
        userPrompt: String,
        onTextChunk: @escaping (String) -> Void
    ) async throws -> String {
        let chatURLString = "\(workerBaseURL)/chat"
        guard let chatURL = URL(string: chatURLString) else {
            throw LLMClientError.invalidWorkerURL(chatURLString)
        }

        var chatRequest = URLRequest(url: chatURL)
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        chatRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        chatRequest.httpBody = try JSONSerialization.data(withJSONObject: makeAnthropicMessagesRequestBody(
            screenshots: screenshots,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        ))

        let streamActivityTracker = StreamActivityTracker()
        let streamReadingTask = Task { @MainActor () throws -> String in
            try await self.readStreamingAnswer(
                for: chatRequest,
                streamActivityTracker: streamActivityTracker,
                onTextChunk: onTextChunk
            )
        }

        // The watchdog cancels the reading task when the worker goes quiet; cancelling
        // the task tears down the URLSession byte stream, which unblocks the read loop.
        let watchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                let secondsSinceLastActivity = Date().timeIntervalSince(streamActivityTracker.dateOfLastActivity)
                if !streamActivityTracker.hasReceivedFirstByte, secondsSinceLastActivity > secondsToWaitForFirstByte {
                    streamActivityTracker.timeoutError = .noResponseBeforeTimeout(seconds: Int(secondsToWaitForFirstByte))
                    streamReadingTask.cancel()
                    return
                }
                if streamActivityTracker.hasReceivedFirstByte, secondsSinceLastActivity > secondsOfSilenceBeforeStreamIsStalled {
                    streamActivityTracker.timeoutError = .streamStalled(seconds: Int(secondsOfSilenceBeforeStreamIsStalled))
                    streamReadingTask.cancel()
                    return
                }
            }
        }
        defer { watchdogTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await streamReadingTask.value
            } onCancel: {
                streamReadingTask.cancel()
            }
        } catch {
            // A watchdog cancellation surfaces as URLError.cancelled / CancellationError;
            // report the real reason instead.
            if let timeoutError = streamActivityTracker.timeoutError { throw timeoutError }
            throw error
        }
    }

    /// One plain, non-streaming text request: system prompt + one user
    /// message, no images, the reply's text blocks joined. Used for sketches,
    /// which need the whole page at once rather than sentence by sentence.
    /// The worker answers `stream: false` with the Anthropic JSON shape
    /// (`content: [{type: "text", text}]`) whichever brain is behind it.
    func requestPlainTextAnswer(
        systemPrompt: String,
        userPrompt: String,
        maximumOutputTokens requestedMaximumOutputTokens: Int,
        secondsToWaitForWholeAnswer: TimeInterval = 90
    ) async throws -> String {
        let chatURLString = "\(workerBaseURL)/chat"
        guard let chatURL = URL(string: chatURLString) else {
            throw LLMClientError.invalidWorkerURL(chatURLString)
        }

        var chatRequest = URLRequest(url: chatURL)
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        chatRequest.setValue("application/json", forHTTPHeaderField: "accept")
        // A few thousand tokens of markup can take a while to write; this is
        // the only limit on the whole call, so it is generous.
        chatRequest.timeoutInterval = secondsToWaitForWholeAnswer
        chatRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": requestedMaximumOutputTokens,
            "stream": false,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
        ] as [String: Any])

        let (responseBodyData, urlResponse) = try await urlSession.data(for: chatRequest)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            let responseBody = String(data: responseBodyData, encoding: .utf8) ?? "<\(responseBodyData.count) non-UTF-8 bytes>"
            throw LLMClientError.httpError(statusCode: statusCode, responseBody: responseBody)
        }

        guard let responsePayload = try? JSONSerialization.jsonObject(with: responseBodyData) as? [String: Any] else {
            throw LLMClientError.streamReportedError("the reply wasn't JSON")
        }
        if let errorDetails = responsePayload["error"] as? [String: Any] {
            throw LLMClientError.streamReportedError(errorDetails["message"] as? String ?? "unknown error")
        }
        let contentBlocks = responsePayload["content"] as? [[String: Any]] ?? []
        let replyText = contentBlocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return replyText
    }

    private func readStreamingAnswer(
        for chatRequest: URLRequest,
        streamActivityTracker: StreamActivityTracker,
        onTextChunk: @escaping (String) -> Void
    ) async throws -> String {
        let (responseByteStream, urlResponse) = try await urlSession.bytes(for: chatRequest)
        streamActivityTracker.recordActivity()

        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            var responseBodyBytes = Data()
            for try await responseByte in responseByteStream {
                responseBodyBytes.append(responseByte)
                streamActivityTracker.recordActivity()
            }
            let responseBody = String(data: responseBodyBytes, encoding: .utf8) ?? "<\(responseBodyBytes.count) non-UTF-8 bytes>"
            throw LLMClientError.httpError(statusCode: statusCode, responseBody: responseBody)
        }

        var accumulatedAnswerText = ""
        for try await serverSentEventLine in responseByteStream.lines {
            streamActivityTracker.recordActivity()
            guard serverSentEventLine.hasPrefix("data:") else { continue }
            let eventPayloadText = serverSentEventLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard
                let eventPayloadData = eventPayloadText.data(using: .utf8),
                let eventPayload = try? JSONSerialization.jsonObject(with: eventPayloadData) as? [String: Any],
                let eventType = eventPayload["type"] as? String
            else { continue }

            switch eventType {
            case "content_block_delta":
                if let delta = eventPayload["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let deltaText = delta["text"] as? String,
                   !deltaText.isEmpty {
                    accumulatedAnswerText += deltaText
                    onTextChunk(accumulatedAnswerText)
                }
            case "error":
                let errorDetails = eventPayload["error"] as? [String: Any]
                let errorMessage = errorDetails?["message"] as? String ?? eventPayloadText
                throw LLMClientError.streamReportedError(errorMessage)
            case "message_stop":
                return accumulatedAnswerText
            default:
                continue
            }
        }
        return accumulatedAnswerText
    }

    private func makeAnthropicMessagesRequestBody(
        screenshots: [CapturedScreen],
        systemPrompt: String,
        conversationHistory: [ConversationTurn],
        userPrompt: String
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        // History is text only: re-sending old screenshots would multiply cost and latency.
        for previousTurn in conversationHistory {
            messages.append(["role": "user", "content": previousTurn.userText])
            messages.append(["role": "assistant", "content": previousTurn.assistantText])
        }

        var currentUserContentBlocks: [[String: Any]] = []
        for screenshot in screenshots {
            currentUserContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": screenshot.jpegImageData.base64EncodedString(),
                ],
            ])
            // The label right after each image tells the model which screen it is and its pixel size.
            currentUserContentBlocks.append(["type": "text", "text": screenshot.label])
        }
        currentUserContentBlocks.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": currentUserContentBlocks])

        return [
            "model": model,
            "max_tokens": maximumOutputTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": messages,
        ]
    }
}

/// Shared between the reading task and the watchdog (both on the main actor).
@MainActor
private final class StreamActivityTracker {
    private(set) var dateOfLastActivity = Date()
    private(set) var hasReceivedFirstByte = false
    var timeoutError: LLMClientError?

    func recordActivity() {
        dateOfLastActivity = Date()
        hasReceivedFirstByte = true
    }
}
