//
//  HootController.swift
//  Hoot
//
//  The coordinator: push-to-talk → screenshot (+ YouTube context) → LLM →
//  streamed Cartesia speech, [POINT:] pointing, [VIDEO:] explainer
//  requests, recent questions, memory ([CONCEPT:] capture, recall of past
//  confusions into the prompt) and spaced-review turns ([REVIEW:]).
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Posted when the user starts talking, so the menu bar panel gets out of the way.
    static let hootDismissMenuPanel = Notification.Name("hootDismissMenuPanel")
}

@MainActor
final class HootController: ObservableObject {
    static let workerBaseURL = "http://localhost:8787"

    enum VoiceState {
        case idle
        case listening
        /// Waiting on the transcript or the first spoken sentence (pet thinks).
        case processing
        /// The answer is being spoken.
        case responding
    }

    /// What the tutor asked the studio to animate, plus the context it needs.
    struct ExplainerVideoRequest: Equatable {
        let question: String
        let brief: String
        let spokenAnswer: String
        /// Set when the question was asked over a paused YouTube video.
        var youTubeContext: StudioYouTubeContext? = nil
    }

    // MARK: Published state for the UI

    @Published private(set) var voiceState: VoiceState = .idle
    /// The answer text revealed so far, in step with the voice.
    @Published private(set) var streamingResponseText = ""
    /// True from submit until the response task ends (the answer has been
    /// fully spoken, or failed, or was interrupted by a new question).
    @Published private(set) var isAnswerPipelineRunning = false
    /// Live transcript while listening, and the mic level for the bars.
    @Published private(set) var liveTranscript = ""
    @Published private(set) var audioPowerLevel: CGFloat = 0

    /// Where to point (AppKit global coordinates), set from a [POINT:] tag.
    @Published private(set) var detectedElementScreenLocation: CGPoint?
    @Published private(set) var detectedElementDisplayFrame: CGRect?
    @Published private(set) var detectedElementLabel: String?
    /// The element's size in points when the tutor boxed it; nil = unknown.
    @Published private(set) var detectedElementBoxSize: CGSize?

    @Published var latestExplainerVideoRequest: ExplainerVideoRequest?
    /// The memory saved for the most recent question that asked for an
    /// explainer video, so the finished video can be attached to it. Nil when
    /// that question wasn't remembered (chit-chat).
    private(set) var memoryEntryIdForMostRecentExplainerVideoRequest: UUID?

    /// A spaced-review quick check the learner is answering. Set by
    /// `beginReviewTurn` (or holding ⌃⌥ while a review nudge is up) and
    /// consumed by the next question, which is graded instead of remembered.
    struct ReviewTurn: Equatable {
        let concept: String
        let question: String
    }
    @Published private(set) var activeReviewTurn: ReviewTurn?
    /// Called after a review answer graded "forgot" when the concept has a
    /// saved explainer video, so the app can offer it again.
    var onReviewForgotWithSavedVideo: ((MemoryEntry) -> Void)?
    /// Set by the app delegate from the explainer panel's phase.
    @Published var isExplainerVideoPlaying = false

    /// "always visible" in settings: show hoot dozing in the corner.
    @Published private(set) var isCornerPetEnabled = true
    @Published private(set) var selectedModel = "claude-sonnet-5-5"

    let permissionCenter = PermissionCenter()
    let youTubeContextProvider = YouTubeContextProvider(workerBaseURL: HootController.workerBaseURL)

    /// True while the push-to-talk keys are held down.
    @Published private(set) var isPushToTalkKeyHeld = false

    // MARK: Collaborators

    let voiceInputController = VoiceInputController(workerBaseURL: HootController.workerBaseURL)
    private let pushToTalkKeyMonitor = PushToTalkKeyMonitor()
    private let llmClient: LLMClient
    private let cartesiaTTSClient = CartesiaTTSClient(proxyURL: "\(HootController.workerBaseURL)/tts")
    /// Used only when Cartesia or the brain is unreachable, so hoot never goes silent.
    private let fallbackSpeechSynthesizer = NSSpeechSynthesizer()

    // MARK: Pipeline bookkeeping

    private static let cornerPetEnabledDefaultsKey = "hootCornerPetEnabled"
    private static let selectedModelDefaultsKey = "hootSelectedModel"
    private static let maximumConversationTurnsKept = 10
    /// How long a hands-free review answer may take before we stop listening.
    private static let secondsToListenForReviewAnswer: Double = 20
    /// Transcript lines (the end of the window) used to look up related memories.
    private static let transcriptLinesUsedForMemoryRecall = 3

    private var conversationHistory: [LLMClient.ConversationTurn] = []
    private var currentAnswerTask: Task<Void, Never>?
    /// Bumped on every new hold and every new question. Anything finishing
    /// for an older generation must not touch the published state, because a
    /// newer question already owns it. This is what keeps cancelled answers
    /// from leaving hoot stuck in "thinking".
    private var answerGeneration = 0
    /// Started on key-down. Resolves to true when this question paused a
    /// YouTube video, so stale context from an earlier video is never used.
    private var currentQuestionYouTubePauseTask: Task<Bool, Never>?
    /// Set when Cartesia failed before a single clip played for this answer.
    private var didTextToSpeechFailBeforeAnyAudio = false
    private var hasStarted = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let userDefaults = UserDefaults.standard
        let storedSelectedModel = userDefaults.string(forKey: Self.selectedModelDefaultsKey) ?? "claude-sonnet-5-5"
        llmClient = LLMClient(workerBaseURL: Self.workerBaseURL, model: storedSelectedModel)
        selectedModel = storedSelectedModel
        if userDefaults.object(forKey: Self.cornerPetEnabledDefaultsKey) != nil {
            isCornerPetEnabled = userDefaults.bool(forKey: Self.cornerPetEnabledDefaultsKey)
        }
        wireVoiceInput()

        // "forget everything" also forgets this session's conversation.
        NotificationCenter.default.publisher(for: .hootMemoryWasForgotten)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.conversationHistory = [] }
            .store(in: &cancellables)
    }

    /// True while any sentence of the answer is queued or playing.
    var isSpeakingResponseAloud: Bool {
        cartesiaTTSClient.isPlaying || fallbackSpeechSynthesizer.isSpeaking
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        permissionCenter.startPolling()
        pushToTalkKeyMonitor.keyTransitions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyTransition in
                switch keyTransition {
                case .pressed: self?.handlePushToTalkPressed()
                case .released: self?.handlePushToTalkReleased()
                }
            }
            .store(in: &cancellables)
        pushToTalkKeyMonitor.startMonitoring()
    }

    func stop() {
        pushToTalkKeyMonitor.stopMonitoring()
        voiceInputController.cancelListening()
        cancelCurrentAnswerAndSpeech()
        isPushToTalkKeyHeld = false
        voiceState = .idle
    }

    func setCornerPetEnabled(_ isEnabled: Bool) {
        isCornerPetEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.cornerPetEnabledDefaultsKey)
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        llmClient.model = model
        UserDefaults.standard.set(model, forKey: Self.selectedModelDefaultsKey)
    }

    /// Called by the overlay when the pet has finished pointing.
    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementLabel = nil
        detectedElementBoxSize = nil
    }

    // MARK: - Voice input wiring

    private func wireVoiceInput() {
        voiceInputController.$liveTranscript
            .sink { [weak self] transcript in self?.liveTranscript = transcript }
            .store(in: &cancellables)
        voiceInputController.$audioPowerLevel
            .sink { [weak self] powerLevel in self?.audioPowerLevel = powerLevel }
            .store(in: &cancellables)

        voiceInputController.onQuestionReady = { [weak self] questionText in
            self?.answerQuestion(questionText)
        }

        // If a hold ends without a question (silence, a mis-press, a dropped
        // stream), onQuestionReady never fires. Watch the input go quiet and
        // fall back to idle so hoot is never stuck "listening". Delivered on
        // the next runloop turn because @Published fires before the value
        // changes, and so onQuestionReady (if any) has had its chance first.
        voiceInputController.$isListening
            .combineLatest(voiceInputController.$isFinishingTranscript)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.returnToIdleIfHoldEndedWithoutQuestion() }
            .store(in: &cancellables)
    }

    private func returnToIdleIfHoldEndedWithoutQuestion() {
        guard voiceState == .listening,
              !isPushToTalkKeyHeld,
              !isAnswerPipelineRunning,
              !voiceInputController.isListening,
              !voiceInputController.isFinishingTranscript else { return }
        voiceState = .idle
        // A review turn with no answer: try again a little later instead of
        // grading silence.
        if let unansweredReviewTurn = activeReviewTurn {
            activeReviewTurn = nil
            MemoryStore.shared.postponeReview(
                forConcept: unansweredReviewTurn.concept,
                bySeconds: SpacedReviewSchedule.laterPostponementInSeconds
            )
        }
        // Nothing was asked, so give the lecture back.
        Task { await youTubeContextProvider.resumeVideoIfWePausedIt() }
    }

    // MARK: - Push to talk

    private func handlePushToTalkPressed() {
        guard !isPushToTalkKeyHeld else { return }
        isPushToTalkKeyHeld = true
        NotificationCenter.default.post(name: .hootDismissMenuPanel, object: nil)

        // Holding ⌃⌥ while a review nudge is up answers it.
        if activeReviewTurn == nil, let offeredReview = SpacedReviewScheduler.shared.reviewOfferedByVisibleNudge() {
            activeReviewTurn = ReviewTurn(concept: offeredReview.concept, question: offeredReview.question)
            NudgeCenter.shared.dismissCurrentNudge(wasIgnored: false)
        }

        // A new question interrupts whatever hoot was doing.
        cancelCurrentAnswerAndSpeech()
        clearDetectedElementLocation()
        streamingResponseText = ""

        // Pause YouTube right away so the lecture doesn't keep talking over
        // the question. Fire-and-forget: dictation must never wait on this.
        currentQuestionYouTubePauseTask = Task {
            let pausedVideoSnapshot = await youTubeContextProvider.pauseVideo()
            return pausedVideoSnapshot != nil
        }

        voiceState = .listening
        voiceInputController.beginListening()
    }

    private func handlePushToTalkReleased() {
        guard isPushToTalkKeyHeld else { return }
        isPushToTalkKeyHeld = false
        voiceInputController.finishListening()
        // Covers the case where the input was never really listening (for
        // example the mic failed to start): no state change gets published.
        DispatchQueue.main.async { [weak self] in self?.returnToIdleIfHoldEndedWithoutQuestion() }
    }

    /// Stops the answer task, both voices and the pipeline flag. The task's
    /// own cleanup is skipped (its generation is stale), so it's done here.
    private func cancelCurrentAnswerAndSpeech() {
        answerGeneration += 1
        currentAnswerTask?.cancel()
        currentAnswerTask = nil
        cartesiaTTSClient.stopPlayback()
        if fallbackSpeechSynthesizer.isSpeaking {
            fallbackSpeechSynthesizer.stopSpeaking()
        }
        isAnswerPipelineRunning = false
    }

    // MARK: - Answer pipeline

    private func answerQuestion(_ questionText: String) {
        let trimmedQuestionText = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestionText.isEmpty else { return }

        cancelCurrentAnswerAndSpeech()
        let pipelineGeneration = answerGeneration
        let youTubePauseTaskForThisQuestion = currentQuestionYouTubePauseTask
        // A review turn lasts exactly one answer.
        let reviewTurnForThisQuestion = activeReviewTurn
        activeReviewTurn = nil

        isAnswerPipelineRunning = true
        voiceState = .processing
        streamingResponseText = ""
        clearDetectedElementLocation()

        currentAnswerTask = Task { [weak self] in
            await self?.runAnswerPipeline(
                questionText: trimmedQuestionText,
                reviewTurn: reviewTurnForThisQuestion,
                pipelineGeneration: pipelineGeneration,
                youTubePauseTask: youTubePauseTaskForThisQuestion
            )
        }
    }

    private func isCurrentGeneration(_ pipelineGeneration: Int) -> Bool {
        pipelineGeneration == answerGeneration && !Task.isCancelled
    }

    private func runAnswerPipeline(
        questionText: String,
        reviewTurn: ReviewTurn?,
        pipelineGeneration: Int,
        youTubePauseTask: Task<Bool, Never>?
    ) async {
        var didRequestExplainerVideo = false
        /// Offered after the reply is spoken, so the nudge doesn't talk over it.
        var savedVideoEntryToOfferAfterForgottenReview: MemoryEntry?

        do {
            let capturedScreens = try await ScreenCapturer.captureAllScreens()
            guard isCurrentGeneration(pipelineGeneration) else { return }

            // If this question paused a YouTube video, tell the tutor what
            // the speaker just said. History keeps the plain transcript so
            // the transcript window isn't repeated on every turn.
            var userPromptWithVideoContext = questionText
            if let reviewTurn {
                userPromptWithVideoContext = Self.userTextForReviewAnswer(questionText, reviewTurn: reviewTurn)
            }
            var youTubeContextForExplainerVideo: StudioYouTubeContext?
            var memoryRecallQueryLines = [questionText]
            let didPauseYouTubeVideoForThisQuestion = await youTubePauseTask?.value ?? false
            if didPauseYouTubeVideoForThisQuestion,
               let youTubeLearningContext = await youTubeContextProvider.learningContextForMostRecentPausedVideo() {
                userPromptWithVideoContext += "\n\n" + youTubeLearningContext.promptContextBlock
                memoryRecallQueryLines.append(youTubeLearningContext.title)
                memoryRecallQueryLines.append(contentsOf: Self.lastTranscriptLinesWithoutTimestamps(
                    youTubeLearningContext.transcriptWindowText,
                    lineCount: Self.transcriptLinesUsedForMemoryRecall
                ))
                youTubeContextForExplainerVideo = StudioYouTubeContext(
                    videoId: youTubeLearningContext.videoId,
                    title: youTubeLearningContext.title,
                    t: youTubeLearningContext.currentTimeSeconds,
                    transcriptWindow: youTubeLearningContext.transcriptWindowText ?? ""
                )
                print("📺 YouTube context: \(youTubeLearningContext.title) at \(Int(youTubeLearningContext.currentTimeSeconds))s")
            }
            guard isCurrentGeneration(pipelineGeneration) else { return }

            // Remind the tutor what this learner got stuck on before, so it
            // can connect the dots ("same idea as tuesday"). Not for review
            // answers: those are about one known concept.
            if reviewTurn == nil,
               let pastConfusionsBlock = MemoryRecall.promptContextBlock(forQueryText: memoryRecallQueryLines.joined(separator: "\n")) {
                userPromptWithVideoContext += "\n\n" + pastConfusionsBlock
                print("🧠 recall:\n\(pastConfusionsBlock)")
            }

            var systemPrompt = HootTutorPrompt.systemPromptForCurrentBuddy()
            if let reviewTurn {
                let latestEntryForConcept = MemoryStore.shared.entries(forConcept: reviewTurn.concept).first
                systemPrompt += HootTutorPrompt.reviewModePromptBlock(
                    concept: reviewTurn.concept,
                    reviewQuestion: reviewTurn.question,
                    savedAnswerSummary: latestEntryForConcept?.answerSummary,
                    hasSavedExplainerVideo: MemoryStore.shared.mostRecentEntryWithExplainerVideo(forConcept: reviewTurn.concept) != nil
                )
            }

            // Speak the answer sentence by sentence while it is still being
            // written, instead of waiting for the whole thing.
            let streamingSpeechState = StreamingSpeechState()
            startStreamingSpokenAnswer(pipelineGeneration: pipelineGeneration)

            let fullResponseText = try await llmClient.streamAnswer(
                screenshots: capturedScreens,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPromptWithVideoContext,
                onTextChunk: { [weak self] accumulatedResponseText in
                    guard let self, self.isCurrentGeneration(pipelineGeneration) else { return }
                    self.enqueueCompletedSentences(
                        from: accumulatedResponseText,
                        streamingSpeechState: streamingSpeechState
                    )
                }
            )
            guard isCurrentGeneration(pipelineGeneration) else { return }

            // Pull out the [VIDEO:...] request first, then the pointing tag.
            let spokenText = HootResponseTags.speakableText(from: fullResponseText)
            let explainerVideoParseResult = HootResponseTags.parseExplainerVideoRequest(from: fullResponseText)
            let recentQuestionSourceDescription = youTubeContextForExplainerVideo?.title
                ?? NSWorkspace.shared.frontmostApplication?.localizedName

            // Remember what they got stuck on (skipped for chit-chat and for
            // review answers, which are graded instead).
            var rememberedEntryId: UUID?
            if let reviewTurn {
                let reviewResult = HootResponseTags.parseReviewResult(from: fullResponseText) ?? .shaky
                MemoryStore.shared.recordReviewResult(reviewResult, forConcept: reviewTurn.concept)
                if reviewResult == .forgot {
                    savedVideoEntryToOfferAfterForgottenReview = MemoryStore.shared
                        .mostRecentEntryWithExplainerVideo(forConcept: reviewTurn.concept)
                }
            } else if let concept = HootResponseTags.parseConcept(from: fullResponseText) {
                rememberedEntryId = MemoryStore.shared.recordAnsweredQuestion(
                    question: questionText,
                    concept: concept,
                    answerSummary: HootResponseTags.answerSummary(fromSpokenText: spokenText),
                    sourceTitle: recentQuestionSourceDescription,
                    youTubeVideoId: youTubeContextForExplainerVideo?.videoId,
                    youTubeTimeSeconds: youTubeContextForExplainerVideo?.t
                )
            }

            if let explainerVideoBrief = explainerVideoParseResult.explainerVideoBrief {
                print("🎬 Explainer video requested: \(explainerVideoBrief)")
                didRequestExplainerVideo = true
                memoryEntryIdForMostRecentExplainerVideoRequest = rememberedEntryId
                latestExplainerVideoRequest = ExplainerVideoRequest(
                    question: questionText,
                    brief: explainerVideoBrief,
                    spokenAnswer: spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
                    youTubeContext: youTubeContextForExplainerVideo
                )
            }

            if let pointingTarget = HootResponseTags.parsePointingTarget(from: explainerVideoParseResult.textWithoutVideoTag),
               let resolvedPointingLocation = HootResponseTags.resolvePointingTarget(pointingTarget, capturedScreens: capturedScreens) {
                // Frame and label first, so an observer of the location sees
                // all three already set.
                detectedElementDisplayFrame = resolvedPointingLocation.displayFrame
                detectedElementLabel = pointingTarget.label
                detectedElementBoxSize = resolvedPointingLocation.globalBoxSize
                detectedElementScreenLocation = resolvedPointingLocation.globalLocation
            }

            // Show it under "recent" in the menu bar panel. The source is the
            // YouTube video's title when the question paused one, else the app.
            if reviewTurn == nil {
                RecentQuestionsStore.shared.recordQuestion(
                    questionText: questionText,
                    sourceDescription: recentQuestionSourceDescription,
                    hadExplainerVideo: didRequestExplainerVideo
                )
            }

            let userTextForHistory = reviewTurn.map { Self.userTextForReviewAnswer(questionText, reviewTurn: $0) } ?? questionText
            conversationHistory.append(LLMClient.ConversationTurn(userText: userTextForHistory, assistantText: fullResponseText))
            if conversationHistory.count > Self.maximumConversationTurnsKept {
                conversationHistory.removeFirst(conversationHistory.count - Self.maximumConversationTurnsKept)
            }

            // Speak whatever is left after the last complete sentence, then
            // let the queue drain.
            if !didTextToSpeechFailBeforeAnyAudio {
                let unspokenRemainder = String(spokenText.dropFirst(streamingSpeechState.enqueuedCharacterCount))
                cartesiaTTSClient.enqueueSentence(unspokenRemainder)
            }
            cartesiaTTSClient.finishSpokenAnswer()
            if spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cartesiaTTSClient.stopPlayback()
            }

            // Wait for the whole answer to be spoken; the pipeline (and the
            // pet's talking state) lasts as long as the voice does.
            while cartesiaTTSClient.isPlaying {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard isCurrentGeneration(pipelineGeneration) else { return }
            }

            // Cartesia couldn't speak at all: say the answer in the system
            // voice so it isn't lost.
            if didTextToSpeechFailBeforeAnyAudio {
                let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSpokenText.isEmpty {
                    await speakWithFallbackVoice(trimmedSpokenText, pipelineGeneration: pipelineGeneration)
                }
            }
        } catch {
            guard isCurrentGeneration(pipelineGeneration) else { return }
            NSLog("⚠️ hoot answer error: %@", String(describing: error))
            // Only apologise if nothing was heard yet; a mid-answer failure
            // just ends the answer where it stopped.
            if voiceState != .responding {
                await speakWithFallbackVoice(fallbackUtteranceForCurrentProblem(), pipelineGeneration: pipelineGeneration)
            } else {
                cartesiaTTSClient.stopPlayback()
            }
        }

        guard isCurrentGeneration(pipelineGeneration) else { return }
        voiceState = .idle
        isAnswerPipelineRunning = false
        currentAnswerTask = nil

        if let savedVideoEntryToOfferAfterForgottenReview {
            onReviewForgotWithSavedVideo?(savedVideoEntryToOfferAfterForgottenReview)
        }

        // The explainer panel resumes the video when it closes; otherwise the
        // answer is over, so give the lecture back.
        if !didRequestExplainerVideo {
            await youTubeContextProvider.resumeVideoIfWePausedIt()
        }
    }

    // MARK: - Memory helpers

    /// What the tutor (and the history) sees for a spoken review answer.
    private static func userTextForReviewAnswer(_ spokenAnswer: String, reviewTurn: ReviewTurn) -> String {
        "(my answer to your quick check about \(reviewTurn.concept): \"\(reviewTurn.question)\") \(spokenAnswer)"
    }

    /// The last few transcript lines with their "[mm:ss]" stamps removed.
    private static func lastTranscriptLinesWithoutTimestamps(_ transcriptWindowText: String?, lineCount: Int) -> [String] {
        guard let transcriptWindowText else { return [] }
        let transcriptLines = transcriptWindowText
            .split(whereSeparator: \.isNewline)
            .map { transcriptLine -> String in
                var lineText = Substring(transcriptLine)
                if lineText.hasPrefix("["), let closingBracketIndex = lineText.firstIndex(of: "]") {
                    lineText = lineText[lineText.index(after: closingBracketIndex)...]
                }
                return lineText.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return Array(transcriptLines.suffix(lineCount))
    }

    // MARK: - Spaced review turn

    /// Starts a spaced-review quick check: hoot says the question out loud,
    /// then listens hands-free (AssemblyAI ends the turn when they stop
    /// talking, which submits the answer). Holding ⌃⌥ works too. The next
    /// question is graded instead of remembered.
    func beginReviewTurn(concept: String, question: String) {
        NotificationCenter.default.post(name: .hootDismissMenuPanel, object: nil)
        cancelCurrentAnswerAndSpeech()
        voiceInputController.cancelListening()
        clearDetectedElementLocation()
        streamingResponseText = ""
        // No YouTube video was paused for this answer; don't reuse an old pause.
        currentQuestionYouTubePauseTask = nil
        activeReviewTurn = ReviewTurn(concept: concept, question: question)

        let pipelineGeneration = answerGeneration
        isAnswerPipelineRunning = true
        voiceState = .processing
        currentAnswerTask = Task { [weak self] in
            await self?.speakReviewQuestionThenListen(question, pipelineGeneration: pipelineGeneration)
        }
    }

    private func speakReviewQuestionThenListen(_ reviewQuestion: String, pipelineGeneration: Int) async {
        startStreamingSpokenAnswer(pipelineGeneration: pipelineGeneration)
        cartesiaTTSClient.enqueueSentence(reviewQuestion)
        cartesiaTTSClient.finishSpokenAnswer()
        while cartesiaTTSClient.isPlaying {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard isCurrentGeneration(pipelineGeneration) else { return }
        }
        if didTextToSpeechFailBeforeAnyAudio {
            await speakWithFallbackVoice(reviewQuestion, pipelineGeneration: pipelineGeneration)
        }
        // A beat of quiet so the mic doesn't catch the end of hoot's voice.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard isCurrentGeneration(pipelineGeneration), !isPushToTalkKeyHeld else { return }

        isAnswerPipelineRunning = false
        currentAnswerTask = nil
        voiceState = .listening
        voiceInputController.beginListening()

        // If they never finish a sentence, submit what was heard (or nothing,
        // which ends the review turn and postpones it).
        try? await Task.sleep(nanoseconds: UInt64(Self.secondsToListenForReviewAnswer * 1_000_000_000))
        guard pipelineGeneration == answerGeneration,
              voiceState == .listening,
              !isPushToTalkKeyHeld,
              voiceInputController.isListening else { return }
        voiceInputController.finishListening()
    }

    /// Says what actually went wrong when we can tell; a rebuild with a new
    /// signature often silently drops screen recording permission.
    private func fallbackUtteranceForCurrentProblem() -> String {
        if !permissionCenter.hasScreenRecordingPermission || !permissionCenter.hasScreenContentPermission {
            return "i can't see your screen yet. open my menu bar panel and turn on screen recording, then ask again."
        }
        return "sorry, i couldn't reach my brain just now. try asking me again."
    }

    /// Speaks with the built-in macOS voice and shows the text in the bubble,
    /// returning when it's done (or when a newer question takes over).
    private func speakWithFallbackVoice(_ utterance: String, pipelineGeneration: Int) async {
        guard isCurrentGeneration(pipelineGeneration) else { return }
        cartesiaTTSClient.stopPlayback()
        streamingResponseText = utterance
        voiceState = .responding
        fallbackSpeechSynthesizer.startSpeaking(utterance)
        // Capped so a synthesizer that never reports "done" can't pin the state.
        let speakingStartDate = Date()
        while fallbackSpeechSynthesizer.isSpeaking && Date().timeIntervalSince(speakingStartDate) < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard isCurrentGeneration(pipelineGeneration) else { return }
        }
    }

    // MARK: - Streaming speech

    /// Tracks how much of the streaming answer has been handed to TTS.
    private final class StreamingSpeechState {
        /// Characters of the speakable text already enqueued as sentences.
        var enqueuedCharacterCount = 0
    }

    /// Prepares the TTS queue for a new answer and wires its callbacks to the
    /// pet state and the bubble text.
    private func startStreamingSpokenAnswer(pipelineGeneration: Int) {
        didTextToSpeechFailBeforeAnyAudio = false
        cartesiaTTSClient.onFirstAudioStarted = { [weak self] in
            // Only move thinking → talking for the answer that is still current.
            guard let self, pipelineGeneration == self.answerGeneration, self.voiceState == .processing else { return }
            self.voiceState = .responding
        }
        cartesiaTTSClient.onSpokenTextProgress = { [weak self] spokenTextSoFar in
            guard let self, pipelineGeneration == self.answerGeneration else { return }
            self.streamingResponseText = spokenTextSoFar
        }
        cartesiaTTSClient.onSpeechFailedBeforeAnyAudio = { [weak self] speechError in
            guard let self, pipelineGeneration == self.answerGeneration else { return }
            NSLog("⚠️ TTS error: %@", String(describing: speechError))
            // The pipeline speaks the answer with the system voice once it has
            // the full text; stop feeding Cartesia so it doesn't start mid-answer.
            self.didTextToSpeechFailBeforeAnyAudio = true
        }
        cartesiaTTSClient.beginSpokenAnswer()
    }

    /// Hands every newly completed sentence of the streaming answer to TTS.
    /// Only text before the first tag ("[VIDEO:" / "[POINT:") is spoken.
    /// Very short sentences are held back and joined to the next one so
    /// clips aren't choppy.
    private func enqueueCompletedSentences(from accumulatedResponseText: String, streamingSpeechState: StreamingSpeechState) {
        guard !didTextToSpeechFailBeforeAnyAudio else { return }
        let speakableText: Substring
        if let firstTagStart = accumulatedResponseText.firstIndex(of: "[") {
            speakableText = accumulatedResponseText[..<firstTagStart]
        } else {
            speakableText = accumulatedResponseText[...]
        }
        guard speakableText.count > streamingSpeechState.enqueuedCharacterCount else { return }

        let notYetEnqueuedText = speakableText.dropFirst(streamingSpeechState.enqueuedCharacterCount)
        let minimumSentenceLength = 24
        var sentenceStartOffset = 0
        var characterOffset = 0
        var previousCharacter: Character?

        for character in notYetEnqueuedText {
            characterOffset += 1
            // A sentence ends at . ! ? followed by whitespace.
            let previousCharacterEndsSentence = previousCharacter.map { ".!?".contains($0) } ?? false
            if previousCharacterEndsSentence && character.isWhitespace {
                let sentenceLength = characterOffset - sentenceStartOffset
                if sentenceLength >= minimumSentenceLength {
                    let sentenceText = String(notYetEnqueuedText.dropFirst(sentenceStartOffset).prefix(sentenceLength))
                    cartesiaTTSClient.enqueueSentence(sentenceText)
                    streamingSpeechState.enqueuedCharacterCount += sentenceLength
                    sentenceStartOffset = characterOffset
                }
            }
            previousCharacter = character
        }
    }
}
