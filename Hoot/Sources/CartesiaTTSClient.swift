//
//  CartesiaTTSClient.swift
//  Hoot
//
//  Speaks text with Cartesia Sonic (through the worker's /tts route) and plays it back
//  through the system audio output.
//
//  Answers are spoken sentence by sentence while the LLM is still writing:
//  each sentence is enqueued as soon as it is complete, its audio is fetched
//  right away (in parallel with the others), and clips play back to back in
//  order. While a clip plays, its sentence is revealed in step with the audio
//  so the bubble text never runs ahead of the voice.
//

import AVFoundation
import Foundation

@MainActor
final class CartesiaTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the clip playing right now. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// One sentence waiting to be spoken: its text and the in-flight fetch of its audio.
    private struct QueuedSentence {
        let sentenceText: String
        let audioFetchTask: Task<Data, Error>
        /// 0-based position of this sentence in the current answer.
        let sentenceIndex: Int
        /// Walkthrough: the step whose sentence this is (its frame lands
        /// when this clip starts). nil for ordinary sentences.
        let walkthroughStepIndex: Int?
    }
    /// How many sentences the current answer has enqueued (empty ones don't count).
    private var enqueuedSentenceCount = 0

    private var queuedSentences: [QueuedSentence] = []
    private var playbackLoopTask: Task<Void, Never>?
    private var hasFinishedEnqueueingForCurrentAnswer = true
    /// Sentences already spoken in full for the current answer, joined with spaces.
    private var fullySpokenText = ""
    private var hasStartedPlayingCurrentAnswer = false

    /// Called on every reveal tick with the answer text spoken so far
    /// (finished sentences plus the part of the current one already heard).
    var onSpokenTextProgress: ((String) -> Void)?
    /// Called once per answer, when its first clip starts playing.
    var onFirstAudioStarted: (() -> Void)?
    /// Called once per answer if speaking failed before anything was heard.
    var onSpeechFailedBeforeAnyAudio: ((Error) -> Void)?
    /// Called when each sentence's clip starts (or is skipped after a fetch
    /// failure, so a walkthrough step is never lost): the sentence's index
    /// in the answer and the walkthrough step it carries, if any.
    var onSentenceStarted: ((_ sentenceIndex: Int, _ walkthroughStepIndex: Int?) -> Void)?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Streaming answer API

    /// Starts a new spoken answer, cutting off whatever was playing.
    func beginSpokenAnswer() {
        stopPlayback()
        hasFinishedEnqueueingForCurrentAnswer = false
        fullySpokenText = ""
        hasStartedPlayingCurrentAnswer = false
        enqueuedSentenceCount = 0
    }

    /// Queues one complete sentence. Its audio starts downloading immediately.
    /// `walkthroughStepIndex` tags the sentence that starts a walkthrough step.
    func enqueueSentence(_ sentenceText: String, walkthroughStepIndex: Int? = nil) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }

        let audioFetchTask = Task { [weak self] () throws -> Data in
            guard let self else { throw CancellationError() }
            return try await self.fetchSpeechAudio(for: trimmedSentenceText)
        }
        queuedSentences.append(QueuedSentence(
            sentenceText: trimmedSentenceText,
            audioFetchTask: audioFetchTask,
            sentenceIndex: enqueuedSentenceCount,
            walkthroughStepIndex: walkthroughStepIndex
        ))
        enqueuedSentenceCount += 1
        startPlaybackLoopIfNeeded()
    }

    /// No more sentences are coming for this answer; the queue drains and stops.
    func finishSpokenAnswer() {
        hasFinishedEnqueueingForCurrentAnswer = true
    }

    /// Convenience for one-off phrases: speaks `text` as a single clip.
    /// Returns once the clip has started playing.
    func speakText(_ text: String) async throws {
        beginSpokenAnswer()
        enqueueSentence(text)
        finishSpokenAnswer()
        while isPlaying && !hasStartedPlayingCurrentAnswer {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// True from the moment an answer has something queued until its last clip ends,
    /// including the short gaps between sentences, so the pet keeps talking.
    var isPlaying: Bool {
        if audioPlayer?.isPlaying == true { return true }
        if !queuedSentences.isEmpty { return true }
        return playbackLoopTask != nil
    }

    /// Stops any in-progress playback immediately and drops queued sentences.
    func stopPlayback() {
        playbackLoopTask?.cancel()
        playbackLoopTask = nil
        for queuedSentence in queuedSentences {
            queuedSentence.audioFetchTask.cancel()
        }
        queuedSentences.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        hasFinishedEnqueueingForCurrentAnswer = true
    }

    // MARK: - Playback loop

    private func startPlaybackLoopIfNeeded() {
        guard playbackLoopTask == nil else { return }
        playbackLoopTask = Task { [weak self] in
            await self?.runPlaybackLoop()
        }
    }

    private func runPlaybackLoop() async {
        defer { playbackLoopTask = nil }

        while !Task.isCancelled {
            guard !queuedSentences.isEmpty else {
                // Nothing queued yet: either the LLM is still writing the next
                // sentence, or the answer is complete and we're done.
                if hasFinishedEnqueueingForCurrentAnswer { return }
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            let nextSentence = queuedSentences.removeFirst()
            do {
                let audioData = try await nextSentence.audioFetchTask.value
                guard !Task.isCancelled else { return }
                onSentenceStarted?(nextSentence.sentenceIndex, nextSentence.walkthroughStepIndex)
                try await play(audioData: audioData, revealing: nextSentence.sentenceText)
            } catch is CancellationError {
                return
            } catch {
                print("⚠️ Cartesia TTS: sentence failed: \(error)")
                if !hasStartedPlayingCurrentAnswer {
                    // Nothing heard yet: let the caller fall back. Drop the rest
                    // so the answer isn't spoken from the middle.
                    for queuedSentence in queuedSentences { queuedSentence.audioFetchTask.cancel() }
                    queuedSentences.removeAll()
                    onSpeechFailedBeforeAnyAudio?(error)
                    return
                }
                // Mid-answer failure: skip the sentence but still show its text
                // (and still land its walkthrough step, if it carried one).
                onSentenceStarted?(nextSentence.sentenceIndex, nextSentence.walkthroughStepIndex)
                appendToFullySpokenText(nextSentence.sentenceText)
                onSpokenTextProgress?(fullySpokenText)
            }
        }
    }

    /// Plays one clip and reveals its sentence in step with the audio,
    /// returning when the clip has finished.
    private func play(audioData: Data, revealing sentenceText: String) async throws {
        let player = try AVAudioPlayer(data: audioData)
        audioPlayer = player
        player.play()
        // For the demo cut: exact caption timing and a clean copy of the voice.
        HootDemoLog.recordSpeech(sentenceText: sentenceText, audioData: audioData, durationSeconds: player.duration)

        if !hasStartedPlayingCurrentAnswer {
            hasStartedPlayingCurrentAnswer = true
            onFirstAudioStarted?()
        }

        let clipDuration = max(player.duration, 0.1)
        let spokenTextBeforeThisSentence = fullySpokenText
        let separator = spokenTextBeforeThisSentence.isEmpty ? "" : " "

        while player.isPlaying {
            try Task.checkCancellation()
            // Reveal slightly ahead of the audio so reading never lags behind hearing.
            let revealFraction = min(1, (player.currentTime / clipDuration) * 1.1 + 0.05)
            let revealedCharacterCount = Int(Double(sentenceText.count) * revealFraction)
            // Reveal whole words only, so the bubble never shows "twenty-four se".
            let revealedCharacters = sentenceText.prefix(revealedCharacterCount)
            let revealedPartOfSentence: String
            if revealedCharacterCount >= sentenceText.count {
                revealedPartOfSentence = sentenceText
            } else if let lastSpaceIndex = revealedCharacters.lastIndex(of: " ") {
                revealedPartOfSentence = String(revealedCharacters[..<lastSpaceIndex])
            } else {
                revealedPartOfSentence = ""
            }
            onSpokenTextProgress?(spokenTextBeforeThisSentence + separator + revealedPartOfSentence)
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        appendToFullySpokenText(sentenceText)
        onSpokenTextProgress?(fullySpokenText)
    }

    private func appendToFullySpokenText(_ sentenceText: String) {
        fullySpokenText = fullySpokenText.isEmpty ? sentenceText : fullySpokenText + " " + sentenceText
    }

    // MARK: - Network

    private func fetchSpeechAudio(for text: String) async throws -> Data {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            // The voice and speed picked in the panel's settings. The worker
            // forwards these to Cartesia (voice id + generation_config.speed).
            "voice_id": WaitWhatVoiceSettingsStore.shared.selectedVoice.cartesiaVoiceID,
            "speed": WaitWhatVoiceSettingsStore.shared.speakingSpeed
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CartesiaTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "CartesiaTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        print("🔊 Cartesia TTS: \(data.count / 1024)KB for \"\(text.prefix(40))\"")
        return data
    }
}
