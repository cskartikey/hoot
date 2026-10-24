//
//  AssemblyAIStreamingSession.swift
//  Hoot
//
//  One push-to-talk hold = one AssemblyAI v3 "universal streaming" websocket
//  session. The app talks to AssemblyAI directly (audio never goes through our
//  worker); the worker only hands out short-lived tokens so the real API key
//  never ships inside the app.
//
//  Protocol (https://www.assemblyai.com/docs/api-reference/streaming-api):
//    client → binary frames of 16 kHz PCM16 audio, then {"type":"ForceEndpoint"}
//             and {"type":"Terminate"} to finish
//    server → {"type":"Begin"}, many {"type":"Turn", ...}, {"type":"Termination"}
//

import Foundation

/// One update about a single turn (roughly: one sentence / one breath).
struct AssemblyAITurnUpdate {
    /// Increments per turn within a session; updates for the same turn share it.
    let turnOrder: Int
    let transcript: String
    /// AssemblyAI thinks the speaker has finished this turn.
    let isEndOfTurn: Bool
    /// The transcript has punctuation and casing applied.
    let isFormatted: Bool
}

@MainActor
final class AssemblyAIStreamingSession {
    enum SessionEvent {
        case turnUpdated(AssemblyAITurnUpdate)
        /// AssemblyAI confirmed the end of the session; no more turns follow.
        case sessionTerminated
        /// The token, the connection or AssemblyAI failed. No more events follow.
        case sessionFailed(description: String)
    }

    /// One URLSession for every hold, for the life of the app. Creating and
    /// invalidating a session per hold made later reconnects fail in the
    /// earlier prototype, and a shared session also reuses TLS/DNS work.
    private static let sharedWebSocketURLSession = URLSession(configuration: .default)

    /// Query parameters for AssemblyAI. `u3-rt-pro` resolves to their newest
    /// realtime model (universal-3-6-pro at the time of writing).
    /// min/max_turn_silence: 700 ms of quiet lets AssemblyAI *consider* that
    /// the question is over (it also checks whether the words sound finished);
    /// after 2 s of quiet it always ends the turn. Shorter cut learners off
    /// mid-thought while they looked at their screen.
    private static let streamingQueryItems: [URLQueryItem] = [
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "encoding", value: "pcm_s16le"),
        URLQueryItem(name: "speech_model", value: "u3-rt-pro"),
        URLQueryItem(name: "min_turn_silence", value: "700"),
        URLQueryItem(name: "max_turn_silence", value: "2000"),
        URLQueryItem(name: "format_turns", value: "true"),
    ]

    private let temporaryTokenProvider: AssemblyAITemporaryTokenProvider
    /// Set to nil once the caller no longer cares (after `closeImmediately`
    /// or `finishInBackgroundIgnoringEvents`), so nothing stale leaks out.
    private var eventHandler: ((SessionEvent) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    /// Audio recorded before the websocket is ready (fetching the token and
    /// connecting takes a few hundred ms). Without this buffer the first words
    /// of every question would be lost.
    private var audioChunksWaitingForConnection: [Data] = []
    private var hasReceivedBeginMessage = false
    private var hasRequestedGracefulFinish = false
    private var hasSentFinishMessages = false
    private var isClosed = false
    /// Set when AssemblyAI refuses the connection because the account already
    /// has its maximum number of open sessions (usually the previous hold's
    /// session still wrapping up). That is worth a quick retry.
    private var wasRejectedForTooManyConcurrentSessions = false

    private static let maximumConnectionAttempts = 4
    private static let secondsToWaitBeforeRetryingConnection: Double = 0.7

    init(
        temporaryTokenProvider: AssemblyAITemporaryTokenProvider,
        eventHandler: @escaping (SessionEvent) -> Void
    ) {
        self.temporaryTokenProvider = temporaryTokenProvider
        self.eventHandler = eventHandler
    }

    /// Fetches a token and connects. Audio sent before the connection is up
    /// is buffered and flushed once AssemblyAI says `Begin`.
    func open() {
        Task { @MainActor in
            await connectAndReceiveMessages()
        }
    }

    func sendAudioChunk(_ pcm16AudioChunk: Data) {
        guard !isClosed, !hasRequestedGracefulFinish else { return }
        if hasReceivedBeginMessage, let webSocketTask {
            sendBinaryFrame(pcm16AudioChunk, on: webSocketTask)
        } else {
            audioChunksWaitingForConnection.append(pcm16AudioChunk)
        }
    }

    /// Ends the audio and asks AssemblyAI to wrap up: the last turn arrives
    /// (formatted), then `sessionTerminated`. If we are still connecting, this
    /// happens right after the buffered audio is flushed.
    func requestGracefulFinish() {
        guard !isClosed, !hasRequestedGracefulFinish else { return }
        hasRequestedGracefulFinish = true
        if hasReceivedBeginMessage {
            sendFinishMessagesOnce()
        }
    }

    /// For when the caller is done with this session (question already
    /// submitted, or the hold was cancelled): tell AssemblyAI we are finished
    /// so the session ends cleanly on their side, but stop reporting anything
    /// to the caller. The session keeps itself alive until AssemblyAI confirms
    /// with Termination or a safety timeout passes.
    func finishInBackgroundIgnoringEvents() {
        eventHandler = nil
        guard !isClosed else { return }
        // Nobody will read a transcript of audio still waiting to be sent.
        audioChunksWaitingForConnection.removeAll()
        requestGracefulFinish()
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(3))
            self.closeImmediately()
        }
    }

    /// Drops the connection right now. No further events are delivered.
    func closeImmediately() {
        eventHandler = nil
        guard !isClosed else { return }
        isClosed = true
        audioChunksWaitingForConnection.removeAll()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Connecting

    private func connectAndReceiveMessages() async {
        for connectionAttemptNumber in 1...Self.maximumConnectionAttempts {
            wasRejectedForTooManyConcurrentSessions = false
            await connectOnceAndReceiveMessages()
            guard wasRejectedForTooManyConcurrentSessions, !isClosed else { return }

            if connectionAttemptNumber == Self.maximumConnectionAttempts {
                reportFailureAndClose(description: "AssemblyAI kept refusing: too many concurrent sessions.")
                return
            }
            print("[AssemblyAIStreamingSession] Too many concurrent sessions; retrying (attempt \(connectionAttemptNumber + 1)).")
            // Audio keeps buffering meanwhile, so no words are lost by waiting.
            try? await Task.sleep(for: .seconds(Self.secondsToWaitBeforeRetryingConnection))
            // Nobody wants this session anymore (cancelled / already submitted).
            if eventHandler == nil {
                closeImmediately()
            }
            guard !isClosed else { return }
        }
    }

    private func connectOnceAndReceiveMessages() async {
        let temporaryToken: String
        do {
            temporaryToken = try await temporaryTokenProvider.takeFreshToken()
        } catch {
            reportFailureAndClose(description: "Could not get an AssemblyAI token from the worker: \(error.localizedDescription)")
            return
        }
        guard !isClosed else { return }

        var streamingURLComponents = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        streamingURLComponents.queryItems = Self.streamingQueryItems + [URLQueryItem(name: "token", value: temporaryToken)]
        guard let streamingURL = streamingURLComponents.url else {
            reportFailureAndClose(description: "Could not build the AssemblyAI streaming URL.")
            return
        }

        let newWebSocketTask = Self.sharedWebSocketURLSession.webSocketTask(with: streamingURL)
        webSocketTask = newWebSocketTask
        newWebSocketTask.resume()

        // Messages are read one at a time on the main actor, so they are
        // handled strictly in the order AssemblyAI sent them.
        while !isClosed && !wasRejectedForTooManyConcurrentSessions {
            let receivedMessage: URLSessionWebSocketTask.Message
            do {
                receivedMessage = try await newWebSocketTask.receive()
            } catch {
                guard !isClosed else { return }
                let closeReasonText = newWebSocketTask.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                reportFailureAndClose(
                    description: "AssemblyAI websocket ended (close code \(newWebSocketTask.closeCode.rawValue) \(closeReasonText)): \(error.localizedDescription)"
                )
                return
            }
            guard !isClosed else { return }
            handleReceivedMessage(receivedMessage)
            if wasRejectedForTooManyConcurrentSessions {
                newWebSocketTask.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
            }
        }
    }

    // MARK: - Incoming messages

    private struct AssemblyAIServerMessage: Decodable {
        let type: String?
        let turn_order: Int?
        let transcript: String?
        let end_of_turn: Bool?
        let turn_is_formatted: Bool?
        let error: String?
    }

    private func handleReceivedMessage(_ receivedMessage: URLSessionWebSocketTask.Message) {
        let messageData: Data
        switch receivedMessage {
        case .string(let messageText):
            messageData = Data(messageText.utf8)
        case .data(let rawMessageData):
            messageData = rawMessageData
        @unknown default:
            return
        }
        guard let serverMessage = try? JSONDecoder().decode(AssemblyAIServerMessage.self, from: messageData) else {
            return
        }

        if let assemblyAIErrorText = serverMessage.error {
            if !hasReceivedBeginMessage && assemblyAIErrorText.localizedCaseInsensitiveContains("concurrent") {
                wasRejectedForTooManyConcurrentSessions = true
                return
            }
            reportFailureAndClose(description: "AssemblyAI error: \(assemblyAIErrorText)")
            return
        }

        switch serverMessage.type {
        case "Begin":
            hasReceivedBeginMessage = true
            flushAudioThatWaitedForConnection()
            if hasRequestedGracefulFinish {
                sendFinishMessagesOnce()
            }
        case "Turn":
            let turnUpdate = AssemblyAITurnUpdate(
                turnOrder: serverMessage.turn_order ?? 0,
                transcript: serverMessage.transcript ?? "",
                isEndOfTurn: serverMessage.end_of_turn ?? false,
                isFormatted: serverMessage.turn_is_formatted ?? false
            )
            eventHandler?(.turnUpdated(turnUpdate))
        case "Termination":
            let handlerToNotify = eventHandler
            closeImmediately()
            handlerToNotify?(.sessionTerminated)
        default:
            // SpeechStarted, Heartbeat, etc. — nothing hoot needs.
            break
        }
    }

    // MARK: - Outgoing messages

    private func flushAudioThatWaitedForConnection() {
        guard let webSocketTask else { return }
        for bufferedAudioChunk in audioChunksWaitingForConnection {
            sendBinaryFrame(bufferedAudioChunk, on: webSocketTask)
        }
        audioChunksWaitingForConnection.removeAll()
    }

    private func sendFinishMessagesOnce() {
        guard !hasSentFinishMessages, let webSocketTask else { return }
        hasSentFinishMessages = true
        // ForceEndpoint first so the words still in flight become a final
        // (formatted) turn right away instead of waiting out max_turn_silence;
        // then Terminate so AssemblyAI closes the session and stops billing.
        sendTextFrame(#"{"type":"ForceEndpoint"}"#, on: webSocketTask)
        sendTextFrame(#"{"type":"Terminate"}"#, on: webSocketTask)
    }

    private func sendBinaryFrame(_ frameData: Data, on webSocketTask: URLSessionWebSocketTask) {
        webSocketTask.send(.data(frameData)) { sendError in
            if let sendError {
                print("[AssemblyAIStreamingSession] Audio send failed: \(sendError.localizedDescription)")
            }
        }
    }

    private func sendTextFrame(_ frameText: String, on webSocketTask: URLSessionWebSocketTask) {
        webSocketTask.send(.string(frameText)) { sendError in
            if let sendError {
                print("[AssemblyAIStreamingSession] Control message send failed: \(sendError.localizedDescription)")
            }
        }
    }

    private func reportFailureAndClose(description failureDescription: String) {
        print("[AssemblyAIStreamingSession] \(failureDescription)")
        let handlerToNotify = eventHandler
        closeImmediately()
        handlerToNotify?(.sessionFailed(description: failureDescription))
    }
}

/// Gets single-use AssemblyAI streaming tokens from our worker, keeping one
/// fetched ahead of time so pressing the keys doesn't wait on a network round
/// trip before audio can start flowing to AssemblyAI.
@MainActor
final class AssemblyAITemporaryTokenProvider {
    /// The worker asks AssemblyAI for tokens valid for 480 s; a prefetched
    /// token older than this is thrown away to stay well clear of expiry.
    private static let maximumPrefetchedTokenAgeInSeconds: TimeInterval = 300

    private let transcribeTokenURL: URL
    /// The single in-flight or finished prefetch. Whoever takes it sets it to
    /// nil first, so a token can never be handed out twice.
    private var prefetchedTokenTask: Task<(token: String, fetchedAt: Date), Error>?

    init(workerBaseURL: String) {
        let trimmedWorkerBaseURL = workerBaseURL.hasSuffix("/") ? String(workerBaseURL.dropLast()) : workerBaseURL
        transcribeTokenURL = URL(string: "\(trimmedWorkerBaseURL)/transcribe-token")!
    }

    func prefetchTokenInBackground() {
        guard prefetchedTokenTask == nil else { return }
        let transcribeTokenURL = transcribeTokenURL
        prefetchedTokenTask = Task {
            let fetchedToken = try await Self.fetchTokenFromWorker(transcribeTokenURL: transcribeTokenURL)
            return (token: fetchedToken, fetchedAt: Date())
        }
    }

    func takeFreshToken() async throws -> String {
        defer { prefetchTokenInBackground() }

        if let prefetchTaskToUse = prefetchedTokenTask {
            prefetchedTokenTask = nil
            if let prefetched = try? await prefetchTaskToUse.value,
               Date().timeIntervalSince(prefetched.fetchedAt) < Self.maximumPrefetchedTokenAgeInSeconds {
                return prefetched.token
            }
        }
        return try await Self.fetchTokenFromWorker(transcribeTokenURL: transcribeTokenURL)
    }

    private struct TranscribeTokenResponse: Decodable {
        let token: String
    }

    private static func fetchTokenFromWorker(transcribeTokenURL: URL) async throws -> String {
        var tokenRequest = URLRequest(url: transcribeTokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.timeoutInterval = 10
        let (responseBody, urlResponse) = try await URLSession.shared.data(for: tokenRequest)
        if let httpResponse = urlResponse as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let responseText = String(data: responseBody, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AssemblyAITemporaryTokenProvider",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker /transcribe-token returned \(httpResponse.statusCode): \(responseText)"]
            )
        }
        return try JSONDecoder().decode(TranscribeTokenResponse.self, from: responseBody).token
    }
}
