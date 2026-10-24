//
//  VoiceInputController.swift
//  Hoot
//
//  Push-to-talk: hold ctrl+option to talk. The question is submitted when the
//  learner releases the keys, or earlier, as soon as AssemblyAI says the
//  speaker finished their turn while the keys are still held (only once per
//  hold; the later release is then a no-op).
//
//  Hard rule for this file: every path ends with `isListening == false` and
//  `isFinishingTranscript == false`. An earlier prototype could get stuck
//  "listening" forever, so all exits funnel through `returnToIdle()`.
//

import Combine
import Foundation

/// Microphone → AssemblyAI streaming → the finished question.
@MainActor
final class VoiceInputController: ObservableObject {
    /// True from key-down until the question is submitted or cancelled.
    @Published private(set) var isListening = false
    /// True between "stop listening" and the final transcript arriving.
    @Published private(set) var isFinishingTranscript = false
    /// What the user has said so far in this hold (partial turns included).
    @Published private(set) var liveTranscript = ""
    /// Microphone level, 0...1, for the listening bars.
    @Published private(set) var audioPowerLevel: CGFloat = 0

    /// Called once per hold with the final question text (never empty).
    var onQuestionReady: ((String) -> Void)?

    /// After release we wait at most this long for AssemblyAI's last words;
    /// past that, whatever we already heard is better than a hang.
    private static let maximumSecondsToWaitForFinalTranscript: TimeInterval = 2.5

    private enum HoldPhase {
        /// Nothing going on.
        case idle
        /// Keys held, mic on, audio streaming.
        case listening
        /// Keys released; waiting for AssemblyAI's final turn.
        case finishingAfterRelease
        /// AssemblyAI ended the turn while the keys were still held and we
        /// already submitted. The coming release must do nothing.
        case submittedEarlyWaitingForRelease
    }

    private var currentHoldPhase: HoldPhase = .idle {
        didSet { updatePublishedFlagsFromHoldPhase() }
    }

    private let temporaryTokenProvider: AssemblyAITemporaryTokenProvider
    private let makeSpeechAudioSource: () -> SpeechAudioSource

    private var currentAudioSource: SpeechAudioSource?
    private var currentStreamingSession: AssemblyAIStreamingSession?
    private var finalTranscriptTimeoutTask: Task<Void, Never>?

    /// Finished turns of the current hold, by AssemblyAI's turn order.
    private var finishedTurnTranscriptsByTurnOrder: [Int: String] = [:]
    /// The turn still being spoken, if any.
    private var inProgressTurn: (turnOrder: Int, transcript: String)?

    init(workerBaseURL: String) {
        self.temporaryTokenProvider = AssemblyAITemporaryTokenProvider(workerBaseURL: workerBaseURL)
        self.makeSpeechAudioSource = { MicrophoneSpeechAudioSource() }
        // Have a token ready before the first press, so the first question
        // connects as fast as later ones.
        temporaryTokenProvider.prefetchTokenInBackground()
    }

    /// For the test harness: feed recorded audio instead of the microphone.
    init(workerBaseURL: String, makeSpeechAudioSource: @escaping () -> SpeechAudioSource) {
        self.temporaryTokenProvider = AssemblyAITemporaryTokenProvider(workerBaseURL: workerBaseURL)
        self.makeSpeechAudioSource = makeSpeechAudioSource
        temporaryTokenProvider.prefetchTokenInBackground()
    }

    // MARK: - Public controls

    /// Key went down: start the mic and the AssemblyAI stream.
    func beginListening() {
        switch currentHoldPhase {
        case .idle, .submittedEarlyWaitingForRelease:
            break
        case .listening:
            // Two presses with no release in between (a missed key-up): start over.
            tearDownAudioAndStream()
        case .finishingAfterRelease:
            // Pressed again before the last question's final words arrived.
            // Submit what we heard rather than silently dropping it.
            finishAfterReleaseAndSubmit()
        }

        clearTranscriptState()
        currentHoldPhase = .listening

        let streamingSession = AssemblyAIStreamingSession(temporaryTokenProvider: temporaryTokenProvider) { [weak self] sessionEvent in
            self?.handleStreamingSessionEvent(sessionEvent)
        }
        currentStreamingSession = streamingSession
        streamingSession.open()

        let audioSource = makeSpeechAudioSource()
        currentAudioSource = audioSource
        audioSource.onAudioChunk = { [weak self, weak streamingSession] pcm16AudioChunk in
            guard let self, self.currentHoldPhase == .listening else { return }
            streamingSession?.sendAudioChunk(pcm16AudioChunk)
        }
        audioSource.onAudioLevel = { [weak self] rawAudioLevel in
            self?.smoothAndPublishAudioLevel(rawAudioLevel)
        }
        audioSource.startCapturing { [weak self, weak audioSource] didStartCapturing in
            guard let self, !didStartCapturing else { return }
            // Only react if this is still the same hold; a quick re-press can
            // make an old permission prompt answer late.
            guard let audioSource, audioSource === self.currentAudioSource else { return }
            print("[VoiceInputController] Microphone did not start; ending this hold.")
            self.returnToIdle()
        }
    }

    /// Key came up: finish the turn and submit (no-op if already submitted).
    func finishListening() {
        switch currentHoldPhase {
        case .idle, .finishingAfterRelease:
            return
        case .submittedEarlyWaitingForRelease:
            currentHoldPhase = .idle
        case .listening:
            stopAudioSource()
            currentHoldPhase = .finishingAfterRelease
            guard let currentStreamingSession else {
                // The stream already died; nothing more will arrive.
                finishAfterReleaseAndSubmit()
                return
            }
            currentStreamingSession.requestGracefulFinish()
            finalTranscriptTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.maximumSecondsToWaitForFinalTranscript))
                guard !Task.isCancelled, let self, self.currentHoldPhase == .finishingAfterRelease else { return }
                print("[VoiceInputController] Final transcript took too long; submitting what we have.")
                self.finishAfterReleaseAndSubmit()
            }
        }
    }

    /// Drop the current hold without submitting.
    func cancelListening() {
        returnToIdle()
    }

    // MARK: - AssemblyAI events

    private func handleStreamingSessionEvent(_ sessionEvent: AssemblyAIStreamingSession.SessionEvent) {
        switch sessionEvent {
        case .turnUpdated(let turnUpdate):
            handleTurnUpdate(turnUpdate)
        case .sessionTerminated:
            if currentHoldPhase == .finishingAfterRelease {
                finishAfterReleaseAndSubmit()
            }
        case .sessionFailed(let failureDescription):
            currentStreamingSession = nil
            switch currentHoldPhase {
            case .listening:
                // Without a transcriber there is nothing useful to listen for.
                print("[VoiceInputController] Ending hold, transcription failed: \(failureDescription)")
                returnToIdle()
            case .finishingAfterRelease:
                finishAfterReleaseAndSubmit()
            case .idle, .submittedEarlyWaitingForRelease:
                break
            }
        }
    }

    private func handleTurnUpdate(_ turnUpdate: AssemblyAITurnUpdate) {
        guard currentHoldPhase == .listening || currentHoldPhase == .finishingAfterRelease else { return }

        if turnUpdate.isEndOfTurn {
            finishedTurnTranscriptsByTurnOrder[turnUpdate.turnOrder] = turnUpdate.transcript
            if inProgressTurn?.turnOrder == turnUpdate.turnOrder {
                inProgressTurn = nil
            }
        } else if finishedTurnTranscriptsByTurnOrder[turnUpdate.turnOrder] == nil {
            inProgressTurn = (turnUpdate.turnOrder, turnUpdate.transcript)
        }
        liveTranscript = composeFullTranscript()

        guard turnUpdate.isEndOfTurn, Self.containsRealWords(turnUpdate.transcript) else { return }

        switch currentHoldPhase {
        case .listening:
            // AssemblyAI heard a finished thought while the keys are still down.
            // Answer now instead of making the learner remember to let go.
            // Pure hesitations ("hold on", "um, okay") are not a question, so
            // keep listening for the real one.
            guard !Self.isOnlyAHesitationPhrase(turnUpdate.transcript) else { return }
            submitEarlyWhileKeysAreStillHeld()
        case .finishingAfterRelease:
            // Our ForceEndpoint produced the final turn. Termination follows
            // about a second later, but there is nothing left to wait for
            // unless another turn is still in progress.
            if inProgressTurn == nil {
                finishAfterReleaseAndSubmit()
            }
        case .idle, .submittedEarlyWaitingForRelease:
            break
        }
    }

    // MARK: - Submitting

    private func submitEarlyWhileKeysAreStillHeld() {
        let questionText = composeFullTranscript()
        stopAudioSource()
        // We already have the text; let AssemblyAI close politely in the
        // background without it touching this hold's state anymore.
        currentStreamingSession?.finishInBackgroundIgnoringEvents()
        currentStreamingSession = nil
        currentHoldPhase = .submittedEarlyWaitingForRelease
        audioPowerLevel = 0
        onQuestionReady?(questionText)
    }

    private func finishAfterReleaseAndSubmit() {
        guard currentHoldPhase == .finishingAfterRelease else { return }
        let questionText = composeFullTranscript()
        returnToIdle()
        if Self.containsRealWords(questionText) {
            onQuestionReady?(questionText)
        } else {
            print("[VoiceInputController] Nothing but silence or noise this hold; not submitting.")
        }
    }

    // MARK: - State helpers

    /// The one exit everything funnels into.
    private func returnToIdle() {
        tearDownAudioAndStream()
        currentHoldPhase = .idle
        audioPowerLevel = 0
    }

    private func tearDownAudioAndStream() {
        stopAudioSource()
        // Not closeImmediately(): dropping the socket without AssemblyAI's
        // Termination leaves the session counted against our concurrent-session
        // limit for a while, and the next press then fails with "Too many
        // concurrent sessions". Ending politely in the background avoids that.
        currentStreamingSession?.finishInBackgroundIgnoringEvents()
        currentStreamingSession = nil
        finalTranscriptTimeoutTask?.cancel()
        finalTranscriptTimeoutTask = nil
    }

    private func stopAudioSource() {
        currentAudioSource?.onAudioChunk = nil
        currentAudioSource?.onAudioLevel = nil
        currentAudioSource?.stopCapturing()
        currentAudioSource = nil
        audioPowerLevel = 0
    }

    private func clearTranscriptState() {
        finishedTurnTranscriptsByTurnOrder = [:]
        inProgressTurn = nil
        liveTranscript = ""
    }

    private func updatePublishedFlagsFromHoldPhase() {
        let shouldBeListening = currentHoldPhase == .listening
        let shouldBeFinishing = currentHoldPhase == .finishingAfterRelease
        // Only assign on change so SwiftUI doesn't redraw for nothing.
        if isListening != shouldBeListening { isListening = shouldBeListening }
        if isFinishingTranscript != shouldBeFinishing { isFinishingTranscript = shouldBeFinishing }
    }

    private func composeFullTranscript() -> String {
        var transcriptPieces = finishedTurnTranscriptsByTurnOrder
            .sorted { $0.key < $1.key }
            .map(\.value)
        if let inProgressTurn {
            transcriptPieces.append(inProgressTurn.transcript)
        }
        return transcriptPieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Fast attack, slow release: bars jump up with the voice and fall back
    /// gently instead of flickering between words.
    private func smoothAndPublishAudioLevel(_ rawAudioLevel: Float) {
        guard currentHoldPhase == .listening else { return }
        let rawLevel = CGFloat(rawAudioLevel)
        let smoothingWeightForNewLevel: CGFloat = rawLevel > audioPowerLevel ? 0.6 : 0.15
        audioPowerLevel = audioPowerLevel + (rawLevel - audioPowerLevel) * smoothingWeightForNewLevel
    }

    // MARK: - Transcript text checks

    private static let fillerSoundWords: Set<String> = [
        "um", "uh", "uhm", "umm", "hmm", "hm", "mm", "mhm", "ah", "er", "erm", "oh",
    ]

    private static let hesitationPhrases: Set<String> = [
        "hold on", "wait", "wait wait", "okay", "ok", "so", "um okay", "okay so", "um so",
        "let me see", "let me think", "one sec", "one second", "hang on", "hmm okay", "right", "yeah",
    ]

    private static func lowercaseWords(in transcript: String) -> [String] {
        transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// At least one word that is not just a filler sound. Noise-only holds
    /// produce empty transcripts or lone "um"s and must not become questions.
    static func containsRealWords(_ transcript: String) -> Bool {
        lowercaseWords(in: transcript).contains { !fillerSoundWords.contains($0) }
    }

    static func isOnlyAHesitationPhrase(_ transcript: String) -> Bool {
        let wordsWithoutFillers = lowercaseWords(in: transcript).filter { !fillerSoundWords.contains($0) }
        return hesitationPhrases.contains(wordsWithoutFillers.joined(separator: " "))
    }
}
