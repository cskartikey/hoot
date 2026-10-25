//
//  HootController.swift
//  Hoot
//
//  The coordinator: push-to-talk → screenshot (+ YouTube context, the whole
//  transcript when they ask to find a moment, answered with [SEEK:]) → LLM →
//  streamed Cartesia speech, [POINT:] pointing, [VIDEO:] explainer
//  requests, recent questions, memory ([CONCEPT:] capture, recall of past
//  confusions into the prompt), spaced-review turns ([REVIEW:]) and hoot's
//  own follow-up questions ([PREDICT] guess-first, [CHECK:] quick checks),
//  which the learner's next hold answers.
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

    /// Which pipeline draws the picture the tutor asked for.
    enum ExplainerKind: Equatable {
        /// `[VIDEO:brief]`: the studio renders a narrated Manim video (slow, rich).
        case studioVideo
        /// `[SKETCH:brief]`: the LLM writes one animated SVG page (seconds).
        case sketch
    }

    /// What the tutor asked to have drawn, plus the context it needs. The
    /// name predates sketches; both kinds flow through the same request.
    struct ExplainerVideoRequest: Equatable {
        let question: String
        let brief: String
        let spokenAnswer: String
        /// Set when the question was asked over a paused YouTube video.
        var youTubeContext: StudioYouTubeContext? = nil
        /// Defaults to the studio so older call sites (debug trigger, retries)
        /// keep working unchanged.
        var kind: ExplainerKind = .studioVideo
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
    /// Marks from [DRAW:] tags (global coordinates), revealed over the
    /// pointed thing while hoot talks. Only ever set together with a pointing
    /// target and cleared with it, so they never outlive the frame.
    @Published private(set) var screenAnnotations: [HootResolvedAnnotation] = []

    // MARK: - Napkin sketch
    /// The tutor's [NAPKIN:] diagram, drawn on the screen while hoot talks
    /// (global coordinates, grouped by spoken sentence). Unlike the marks it
    /// outlives pointing: it stays until the next hold or 45 seconds pass,
    /// so the learner can keep looking at it after hoot has flown off.
    @Published private(set) var napkinSketch: HootNapkinSketchState?
    private var napkinSketchExpiryTask: Task<Void, Never>?
    private static let secondsANapkinSketchStaysUp: TimeInterval = 45

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

    /// hoot ended its reply with a question of its own and is waiting for
    /// the learner's next hold to answer it. A prediction defers the real
    /// answer until they guess (learnharness's predict-then-teach); a quick
    /// check is one applied question after an answer, graded like a spaced
    /// review so the result lands on the concept's review ladder.
    struct FollowUpQuestion: Equatable {
        enum Kind: Equatable {
            case prediction
            case quickCheck
        }
        let kind: Kind
        /// What hoot asked, word for word.
        let question: String
        /// Prediction: the learner's original question hoot deferred.
        /// Quick check: the concept being checked.
        let subject: String
        /// Whether the question that asked this paused a YouTube video (it
        /// stays paused until the follow-up is answered or abandoned).
        let didPauseYouTubeVideo: Bool
        let askedDate: Date
    }
    @Published private(set) var pendingFollowUpQuestion: FollowUpQuestion?
    /// "quick checks" in settings: every teaching answer ends with a check.
    @Published private(set) var isQuickCheckAfterAnswersEnabled = false

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
    private static let quickCheckAfterAnswersEnabledDefaultsKey = "hootQuickChecksAfterAnswersEnabled"
    /// After this, an unanswered follow-up question is forgotten.
    private static let secondsAFollowUpQuestionStaysOpen: TimeInterval = 90
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

    /// The model name the settings picked (or the default), read fresh so
    /// other clients (the sketch client) use the same brain as the tutor.
    static var storedSelectedModelName: String {
        UserDefaults.standard.string(forKey: selectedModelDefaultsKey) ?? "claude-sonnet-5-5"
    }

    init() {
        let userDefaults = UserDefaults.standard
        let storedSelectedModel = Self.storedSelectedModelName
        llmClient = LLMClient(workerBaseURL: Self.workerBaseURL, model: storedSelectedModel)
        selectedModel = storedSelectedModel
        if userDefaults.object(forKey: Self.cornerPetEnabledDefaultsKey) != nil {
            isCornerPetEnabled = userDefaults.bool(forKey: Self.cornerPetEnabledDefaultsKey)
        }
        isQuickCheckAfterAnswersEnabled = userDefaults.bool(forKey: Self.quickCheckAfterAnswersEnabledDefaultsKey)
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

    func setQuickCheckAfterAnswersEnabled(_ isEnabled: Bool) {
        isQuickCheckAfterAnswersEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.quickCheckAfterAnswersEnabledDefaultsKey)
    }

    /// Called by the overlay when hoot leaves the cursor without an answer
    /// to its question: forget it and give the lecture back.
    func abandonPendingFollowUpQuestion() {
        guard pendingFollowUpQuestion != nil else { return }
        pendingFollowUpQuestion = nil
        Task { await youTubeContextProvider.resumeVideoIfWePausedIt() }
    }

    /// The open follow-up question, unless it has gone stale.
    private var openFollowUpQuestion: FollowUpQuestion? {
        guard let pendingFollowUpQuestion,
              Date().timeIntervalSince(pendingFollowUpQuestion.askedDate) <= Self.secondsAFollowUpQuestionStaysOpen else {
            return nil
        }
        return pendingFollowUpQuestion
    }

    /// Called by the overlay when the pet has finished pointing.
    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementLabel = nil
        detectedElementBoxSize = nil
        screenAnnotations = []
    }

    // MARK: - Walkthrough

    /// The live walkthrough (docs/design/WALKTHROUGH.md), or nil. Steps are
    /// appended as their [STEP] tags stream in; the phase moves on sentence
    /// starts and, after the last sentence, through the watch-and-confirm
    /// loop. Cleared by the next ⌃⌥ hold.
    @Published private(set) var walkthrough: HootWalkthroughState?
    private var walkthroughRunner: HootWalkthroughRunner?

    /// Each step's spoken sentence, by step index, recorded as the sentences
    /// are handed to TTS. The "just do it" locate call describes the step
    /// with it, and a later bare "just do it" narrates the steps from it.
    private var walkthroughSentenceTextByStepIndex: [Int: String] = [:]

    /// Ends and forgets the walkthrough (a new question, stop).
    private func endWalkthrough() {
        walkthroughRunner?.end()
        walkthroughRunner = nil
        walkthrough = nil
        walkthroughSentenceTextByStepIndex = [:]
        justDoItSession?.executionTask?.cancel()
        justDoItSession = nil
    }

    /// Parses any step tags that have completed in the stream so far and
    /// resolves the new ones to global coordinates, so step k's frame is
    /// ready before sentence k's clip starts. With `startsJustDoItExecution`
    /// the first step also starts hoot's own clicking (MARK: Just do it).
    private func noteWalkthroughSteps(
        inStreamingResponse accumulatedResponseText: String,
        capturedScreens: [CapturedScreen],
        startsJustDoItExecution: Bool,
        pipelineGeneration: Int
    ) {
        let parsedSteps = HootWalkthroughTags.parseSteps(from: accumulatedResponseText)
        guard !parsedSteps.isEmpty else { return }
        let totalStepCount = parsedSteps.map(\.totalStepCount).max() ?? parsedSteps.count
        if walkthroughRunner == nil {
            walkthroughRunner = HootWalkthroughRunner(totalStepCount: totalStepCount) { [weak self] updatedState in
                self?.walkthrough = updatedState
            }
            if startsJustDoItExecution, justDoItSession == nil {
                let session = JustDoItSession(mode: .freshQuestion)
                justDoItSession = session
                session.executionTask = Task { [weak self] in
                    await self?.executeJustDoItSteps(session: session, pipelineGeneration: pipelineGeneration)
                }
            }
        }
        guard let walkthroughRunner else { return }
        let alreadyHandledCount = walkthroughRunner.handledParsedStepCount
        guard parsedSteps.count > alreadyHandledCount else { return }
        walkthroughRunner.handledParsedStepCount = parsedSteps.count
        let newSteps: [HootWalkthroughStep] = parsedSteps[alreadyHandledCount...].enumerated().compactMap { offset, parsedStep in
            guard let resolvedLocation = HootResponseTags.resolvePointingTarget(parsedStep.pointingTarget, capturedScreens: capturedScreens) else { return nil }
            return HootWalkthroughStep(
                stepNumber: alreadyHandledCount + offset + 1,
                label: parsedStep.pointingTarget.label,
                globalCenter: resolvedLocation.globalLocation,
                globalBoxSize: resolvedLocation.globalBoxSize,
                displayFrame: resolvedLocation.displayFrame
            )
        }
        walkthroughRunner.appendSteps(newSteps, totalStepCount: totalStepCount)
    }

    /// Which walkthrough step a sentence occupying `sentenceRange` (character
    /// offsets in the speakable text) starts, if any.
    private func walkthroughStepIndex(forSentenceIn sentenceRange: Range<Int>, responseText: String) -> Int? {
        guard walkthroughRunner != nil else { return nil }
        let stepStartOffsets = HootWalkthroughTags.stripStepTags(from: responseText).stepStartOffsets
        return HootWalkthroughTags.stepIndex(startedBySentenceIn: sentenceRange, stepStartOffsets: stepStartOffsets)
    }

    /// After the steps are spoken: wait, look, confirm (see the runner).
    /// Speaks the verdict sentence with Cartesia; stays cancellable through
    /// the answer generation like the rest of the pipeline.
    private func runWalkthroughWatchAndConfirm(question: String, capturedScreens: [CapturedScreen], pipelineGeneration: Int) async {
        guard let walkthroughRunner, walkthroughRunner.hasSteps else { return }
        // The steps have been spoken: a bare "just do it" on the next hold
        // can now execute them (MARK: Just do it).
        recentWalkthroughForFollowUp = RecentWalkthroughForFollowUp(
            steps: walkthroughRunner.state.steps,
            totalStepCount: walkthroughRunner.state.totalStepCount,
            sentenceTextByStepIndex: walkthroughSentenceTextByStepIndex,
            question: question,
            date: Date()
        )
        await walkthroughRunner.runWatchAndConfirm(
            question: question,
            beforeScreens: capturedScreens,
            llmClient: llmClient,
            speak: { [weak self] sentence in
                await self?.speakOneSentenceAndWait(sentence, pipelineGeneration: pipelineGeneration)
            },
            isCancelled: { [weak self] in
                guard let self else { return true }
                return !self.isCurrentGeneration(pipelineGeneration)
            }
        )
    }

    /// Says one sentence with Cartesia (shown in the bubble) and returns
    /// once it has been heard, or as soon as a newer question takes over.
    private func speakOneSentenceAndWait(_ sentence: String, pipelineGeneration: Int) async {
        guard isCurrentGeneration(pipelineGeneration) else { return }
        streamingResponseText = sentence
        try? await cartesiaTTSClient.speakText(sentence)
        while cartesiaTTSClient.isPlaying, isCurrentGeneration(pipelineGeneration) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Just do it

    /// Hoot's own execution of a walkthrough, when the learner explicitly
    /// asked for it ("how do i share this, just do it"; or a bare "you do
    /// it" right after a walkthrough). Alive from the first step tag (or
    /// the follow-up hold) until the last click or a stop. The executor
    /// (`HootWalkthroughExecutor`) moves the cursor and clicks; this
    /// session is the bookkeeping between the voice, the stream and it.
    private final class JustDoItSession {
        enum Mode {
            /// The tutor is answering a fresh question with step tags; each
            /// step is clicked once its sentence has been spoken.
            case freshQuestion
            /// The steps of the walkthrough hoot gave a moment ago; every
            /// box is re-located because the screen has moved on since.
            case followUpOnRecentWalkthrough
        }
        let mode: Mode
        let executor = HootWalkthroughExecutor()
        /// Steps whose sentence TTS has started. A step is never clicked
        /// before hoot has begun saying it.
        var startedStepIndices: Set<Int> = []
        /// Set once the tutor's stream ended, so the executor knows the
        /// step list is final.
        var hasStreamFinished = false
        var executionTask: Task<Void, Never>?
        var stopReason: HootWalkthroughExecutionStop?
        var clickedStepCount = 0

        init(mode: Mode) {
            self.mode = mode
        }
    }
    private var justDoItSession: JustDoItSession?

    /// The last walkthrough hoot spoke (its boxes and sentences), kept so a
    /// following bare "just do it" can execute it without asking the tutor
    /// again. Dropped by the next ordinary question or after a while.
    private struct RecentWalkthroughForFollowUp {
        let steps: [HootWalkthroughStep]
        let totalStepCount: Int
        let sentenceTextByStepIndex: [Int: String]
        let question: String
        let date: Date
    }
    private var recentWalkthroughForFollowUp: RecentWalkthroughForFollowUp?
    private static let secondsARecentWalkthroughCanBeExecuted: TimeInterval = 120
    /// Between the frame landing on a step and the cursor leaving for it,
    /// so the learner reads frame → cursor flies → click, not all at once.
    private static let secondsBetweenFrameLandingAndCursorFlight: TimeInterval = 0.3
    /// The executor gives up on a step whose sentence never starts (a long
    /// stall) instead of keeping the pipeline alive forever.
    private static let secondsToWaitForAStepSentenceToStart: TimeInterval = 45

    /// The recent walkthrough a bare "just do it" would execute, if there
    /// is one and it is fresh enough.
    private func recentWalkthroughToExecute(forQuestion questionText: String) -> RecentWalkthroughForFollowUp? {
        guard HootTutorPrompt.isBareDoItRequest(questionText),
              let recentWalkthrough = recentWalkthroughForFollowUp,
              Date().timeIntervalSince(recentWalkthrough.date) <= Self.secondsARecentWalkthroughCanBeExecuted else {
            return nil
        }
        return recentWalkthrough
    }

    /// Clicks the walkthrough's steps one at a time, in order. For each
    /// step: wait until hoot has started saying its sentence; from step two
    /// on (or for every step of a follow-up) take a fresh screenshot and
    /// ask where the control is now; slide the frame there; fly the cursor
    /// and click; let the UI settle. Stops at the first reason to (the
    /// learner moved the mouse, a control couldn't be found, a target off
    /// every screen, the explainer panel, a newer question).
    private func executeJustDoItSteps(session: JustDoItSession, pipelineGeneration: Int) async {
        let isCancelled: () -> Bool = { [weak self] in
            guard let self else { return true }
            return !self.isCurrentGeneration(pipelineGeneration)
        }
        func stop(_ reason: HootWalkthroughExecutionStop) {
            session.stopReason = reason
            print("🖱️ just do it stopped: \(reason)")
            // Nothing more is going to be clicked, so stop narrating clicks
            // that won't happen; the stop sentence is spoken by the pipeline.
            if reason != .cancelled { cartesiaTTSClient.stopPlayback() }
        }

        var stepIndex = 0
        while stepIndex < HootWalkthroughExecutor.maximumStepCount {
            // Wait for the step to exist and for its sentence to have started.
            let waitStartDate = Date()
            while !(session.startedStepIndices.contains(stepIndex) && (walkthroughRunner?.state.steps.indices.contains(stepIndex) ?? false)) {
                if isCancelled() { session.stopReason = .cancelled; return }
                if session.hasStreamFinished, let runner = walkthroughRunner, stepIndex >= runner.state.steps.count { return }
                // Cartesia never started: the system voice reads the whole
                // reply at once and no sentence starts will ever arrive.
                if didTextToSpeechFailBeforeAnyAudio { session.startedStepIndices.insert(stepIndex) }
                // A sentence start that never comes must not pin the pipeline.
                if Date().timeIntervalSince(waitStartDate) > Self.secondsToWaitForAStepSentenceToStart {
                    session.stopReason = .cancelled
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let runner = walkthroughRunner else { return }
            var step = runner.state.steps[stepIndex]
            let stepSentence = walkthroughSentenceTextByStepIndex[stepIndex] ?? step.label ?? "step \(step.stepNumber)"

            if session.mode == .followUpOnRecentWalkthrough {
                // Narrate the step hoot gave earlier while its click is prepared.
                streamingResponseText = stepSentence
                try? await cartesiaTTSClient.speakText(stepSentence)
                if isCancelled() { session.stopReason = .cancelled; return }
            }
            if isExplainerVideoPlaying { stop(.explainerPanelIsOpen); return }
            if stepIndex == 0 {
                // From here on the cursor is hoot's; any drift is the learner's.
                session.executor.noteCursorAsPlacedByHootNow()
            }
            if session.executor.learnerHasMovedTheMouse { stop(.learnerMovedTheMouse); return }

            // The tutor's box for a later step is its best guess at a control
            // that may only exist after the earlier click, so look again.
            if stepIndex >= 1 || session.mode == .followUpOnRecentWalkthrough {
                do {
                    guard let freshStep = try await HootWalkthroughLocate.locateStep(step, stepSentence: stepSentence, llmClient: llmClient) else {
                        stop(.controlNotFound(label: step.label))
                        return
                    }
                    if isCancelled() { session.stopReason = .cancelled; return }
                    runner.replaceStep(atIndex: stepIndex, with: freshStep)
                    step = freshStep
                } catch {
                    NSLog("⚠️ just do it: locate failed: %@", String(describing: error))
                    stop(.controlNotFound(label: step.label))
                    return
                }
                if session.executor.learnerHasMovedTheMouse { stop(.learnerMovedTheMouse); return }
            }

            // Frame first, then the cursor, then the click.
            runner.noteSentenceStarted(forStepIndex: stepIndex)
            try? await Task.sleep(nanoseconds: UInt64(Self.secondsBetweenFrameLandingAndCursorFlight * 1_000_000_000))
            if isCancelled() { session.stopReason = .cancelled; return }
            if let stopReason = await session.executor.moveCursorAndClick(at: step.globalCenter, label: step.label, isCancelled: isCancelled) {
                stop(stopReason)
                return
            }
            session.clickedStepCount += 1
            stepIndex += 1
        }
    }

    /// After the reply is spoken: wait for the clicks to catch up, then say
    /// why hoot stopped (if it did) or show the done check. No verdict
    /// watching: hoot did the steps itself.
    private func finishJustDoItExecution(session: JustDoItSession, pipelineGeneration: Int) async {
        if let executionTask = session.executionTask {
            await executionTask.value
        }
        guard isCurrentGeneration(pipelineGeneration) else { return }
        if let stopReason = session.stopReason {
            if let spokenSentence = stopReason.spokenSentence {
                await speakOneSentenceAndWait(spokenSentence, pipelineGeneration: pipelineGeneration)
            }
            walkthroughRunner?.end()
            return
        }
        guard session.clickedStepCount > 0 else {
            walkthroughRunner?.end()
            return
        }
        print("🖱️ just do it: \(session.clickedStepCount) step(s) clicked")
        // A fresh question's closing line is the tutor's own last sentence,
        // already spoken; a follow-up had no reply of its own.
        if session.mode == .followUpOnRecentWalkthrough {
            await speakOneSentenceAndWait("done.", pipelineGeneration: pipelineGeneration)
        }
        walkthroughRunner?.finishAsDoneByHoot()
        // Long enough for the check to draw before the frame goes out.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        walkthroughRunner?.end()
    }

    /// The whole answer for a bare "just do it" after a walkthrough: no
    /// tutor call; the steps hoot gave a moment ago are re-located on the
    /// screen as it is now, narrated and clicked one by one.
    private func runJustDoItFollowUpPipeline(_ recentWalkthrough: RecentWalkthroughForFollowUp, pipelineGeneration: Int) async {
        // One execution per walkthrough: a second "do it" would re-click.
        recentWalkthroughForFollowUp = nil

        let runner = HootWalkthroughRunner(totalStepCount: recentWalkthrough.totalStepCount) { [weak self] updatedState in
            self?.walkthrough = updatedState
        }
        runner.appendSteps(recentWalkthrough.steps, totalStepCount: recentWalkthrough.totalStepCount)
        runner.handledParsedStepCount = recentWalkthrough.steps.count
        walkthroughRunner = runner
        walkthroughSentenceTextByStepIndex = recentWalkthrough.sentenceTextByStepIndex

        let session = JustDoItSession(mode: .followUpOnRecentWalkthrough)
        // Every step was already said; the executor narrates each one itself.
        session.startedStepIndices = Set(recentWalkthrough.steps.indices)
        session.hasStreamFinished = true
        justDoItSession = session

        startStreamingSpokenAnswer(pipelineGeneration: pipelineGeneration)
        await speakOneSentenceAndWait("on it.", pipelineGeneration: pipelineGeneration)
        guard isCurrentGeneration(pipelineGeneration) else { return }
        await executeJustDoItSteps(session: session, pipelineGeneration: pipelineGeneration)
        await finishJustDoItExecution(session: session, pipelineGeneration: pipelineGeneration)

        guard isCurrentGeneration(pipelineGeneration) else { return }
        walkthroughRunner?.end()
        justDoItSession = nil
        voiceState = .idle
        isAnswerPipelineRunning = false
        currentAnswerTask = nil
        // The hold paused the video like any question; hoot's clicks are over.
        await youTubeContextProvider.resumeVideoIfWePausedIt()
    }

    // MARK: - Napkin sketch

    /// Takes the napkin off the screen (the overlay fades it out).
    func clearNapkinSketch() {
        napkinSketchExpiryTask?.cancel()
        napkinSketchExpiryTask = nil
        if napkinSketch != nil { napkinSketch = nil }
    }

    /// Parses the reply's [NAPKIN:] block, places the paper beside what
    /// hoot is pointing at (or beside the cursor) and publishes it; nothing
    /// happens when the reply has no block. The napkin clears itself after
    /// a while so it can't be left behind on the screen.
    private func publishNapkinSketch(
        fromResponseText responseText: String,
        spokenText: String,
        capturedScreens: [CapturedScreen],
        pointingLocation: HootResolvedPointingLocation?
    ) {
        napkinSketchExpiryTask?.cancel()
        napkinSketchExpiryTask = nil
        guard let napkinSketchState = HootNapkinLayout.napkinSketchState(
            fromResponseText: responseText,
            spokenText: spokenText,
            capturedScreens: capturedScreens,
            pointingLocation: pointingLocation
        ) else {
            if responseText.range(of: "[NAPKIN", options: .caseInsensitive) != nil {
                print("⚠️ Napkin block present but nothing usable was parsed from it")
            }
            if napkinSketch != nil { napkinSketch = nil }
            return
        }
        print("🧻 Napkin sketch: \(napkinSketchState.strokes.count) stroke(s) over \(napkinSketchState.sentenceCount) sentence(s)")
        napkinSketch = napkinSketchState
        napkinSketchExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.secondsANapkinSketchStaysUp * 1_000_000_000))
            guard !Task.isCancelled, let self, self.napkinSketch == napkinSketchState else { return }
            self.napkinSketch = nil
        }
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
        // Nothing was asked, so give the lecture back, unless hoot is still
        // waiting on an answer to its own question (abandoning that resumes).
        if pendingFollowUpQuestion == nil {
            Task { await youTubeContextProvider.resumeVideoIfWePausedIt() }
        }
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
        clearNapkinSketch() // MARK: - Napkin sketch (a new hold wipes the napkin)
        streamingResponseText = ""

        // Pause YouTube right away so the lecture doesn't keep talking over
        // the question. Fire-and-forget: dictation must never wait on this.
        // While hoot's own question is open the video is still paused from
        // the question that asked it; pausing again would read "already
        // paused" and we'd never resume it, so reuse that question's answer.
        if let openFollowUpQuestion {
            let didThatQuestionPauseTheVideo = openFollowUpQuestion.didPauseYouTubeVideo
            currentQuestionYouTubePauseTask = Task { didThatQuestionPauseTheVideo }
        } else {
            currentQuestionYouTubePauseTask = Task {
                let pausedVideoSnapshot = await youTubeContextProvider.pauseVideo()
                return pausedVideoSnapshot != nil
            }
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
        // Any new question ends a walkthrough (MARK: Walkthrough).
        endWalkthrough()
    }

    // MARK: - Answer pipeline

    private func answerQuestion(_ questionText: String) {
        let trimmedQuestionText = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestionText.isEmpty else { return }
        HootDemoLog.recordQuestion(trimmedQuestionText)

        cancelCurrentAnswerAndSpeech()
        let pipelineGeneration = answerGeneration
        let youTubePauseTaskForThisQuestion = currentQuestionYouTubePauseTask
        // A review turn lasts exactly one answer, and so does hoot's own
        // follow-up question (a review nudge outranks it).
        let reviewTurnForThisQuestion = activeReviewTurn
        activeReviewTurn = nil
        let followUpQuestionForThisAnswer = reviewTurnForThisQuestion == nil ? openFollowUpQuestion : nil
        pendingFollowUpQuestion = nil

        isAnswerPipelineRunning = true
        voiceState = .processing
        streamingResponseText = ""
        clearDetectedElementLocation()

        // A bare "just do it" right after a walkthrough executes that
        // walkthrough instead of asking the tutor (MARK: Just do it). Any
        // other question forgets it, so a later "do it" can't replay it.
        if reviewTurnForThisQuestion == nil, followUpQuestionForThisAnswer == nil,
           let recentWalkthrough = recentWalkthroughToExecute(forQuestion: trimmedQuestionText) {
            print("🖱️ just do it: executing the walkthrough for \"\(recentWalkthrough.question)\"")
            currentAnswerTask = Task { [weak self] in
                await self?.runJustDoItFollowUpPipeline(recentWalkthrough, pipelineGeneration: pipelineGeneration)
            }
            return
        }
        recentWalkthroughForFollowUp = nil

        currentAnswerTask = Task { [weak self] in
            await self?.runAnswerPipeline(
                questionText: trimmedQuestionText,
                reviewTurn: reviewTurnForThisQuestion,
                followUpQuestion: followUpQuestionForThisAnswer,
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
        followUpQuestion: FollowUpQuestion?,
        pipelineGeneration: Int,
        youTubePauseTask: Task<Bool, Never>?
    ) async {
        var didRequestExplainerVideo = false
        /// Offered after the reply is spoken, so the nudge doesn't talk over it.
        var savedVideoEntryToOfferAfterForgottenReview: MemoryEntry?
        /// Set when this reply ends with hoot's own question ([PREDICT] /
        /// [CHECK:]); the video then stays paused for the answer.
        var didAskAFollowUpQuestion = false
        /// Set from a [SEEK:mm:ss] tag: once the reply is spoken, the video
        /// jumps there and plays instead of merely resuming.
        var seekTargetSecondsAfterSpeaking: Double?
        /// For a guess, the records (memory, recent) carry the question hoot
        /// deferred, not the guess itself.
        let questionTextForRecords = followUpQuestion?.kind == .prediction ? followUpQuestion!.subject : questionText

        do {
            let capturedScreens = try await ScreenCapturer.captureAllScreens()
            guard isCurrentGeneration(pipelineGeneration) else { return }

            // If this question paused a YouTube video, tell the tutor what
            // the speaker just said. History keeps the plain transcript so
            // the transcript window isn't repeated on every turn.
            var userPromptWithVideoContext = questionText
            if let reviewTurn {
                userPromptWithVideoContext = Self.userTextForReviewAnswer(questionText, reviewTurn: reviewTurn)
            } else if let followUpQuestion {
                userPromptWithVideoContext = Self.userTextForFollowUpAnswer(questionText, followUpQuestion: followUpQuestion)
            } else if let explicitPictureDirective = HootTutorPrompt.explicitPictureDirective(forQuestion: questionText) {
                // An explicit "draw it" / "make a video" is enforced, not left
                // to the prose rules in the system prompt.
                userPromptWithVideoContext += "\n\n" + explicitPictureDirective
            }
            // "how do i share this doc, just do it": the reply must be a
            // walkthrough, and hoot clicks its steps (MARK: Just do it).
            // The explicit phrase is the authorization; without
            // Accessibility the clicks would be dropped, so hoot points
            // instead and says why.
            // Never while the explainer panel is open: then it is an
            // ordinary walkthrough, pointing only.
            let questionAsksHootToDoIt = reviewTurn == nil && followUpQuestion == nil
                && HootTutorPrompt.questionAsksHootToDoItForThem(questionText)
            let startsJustDoItExecution = questionAsksHootToDoIt && HootWalkthroughExecutor.canPostMouseEvents && !isExplainerVideoPlaying
            if startsJustDoItExecution {
                userPromptWithVideoContext += "\n\n" + HootTutorPrompt.doItForMeDirective
                print("🖱️ just do it asked")
            } else if questionAsksHootToDoIt, !HootWalkthroughExecutor.canPostMouseEvents {
                userPromptWithVideoContext += "\n\n" + HootTutorPrompt.doItForMeWithoutAccessibilityDirective
                print("🖱️ just do it asked, but accessibility is off: pointing only")
            } else if questionAsksHootToDoIt {
                print("🖱️ just do it asked while the explainer panel is open: pointing only")
            }
            var youTubeContextForExplainerVideo: StudioYouTubeContext?
            var memoryRecallQueryLines = [questionText]
            let didPauseYouTubeVideoForThisQuestion = await youTubePauseTask?.value ?? false
            // "go back to where she explained X" needs the whole transcript,
            // not the last ninety seconds, so the tutor can pick a [SEEK:].
            let questionAsksToFindAMomentInTheVideo = reviewTurn == nil && followUpQuestion == nil
                && HootTutorPrompt.questionAsksToFindAMomentInTheVideo(questionText)
            if didPauseYouTubeVideoForThisQuestion,
               let youTubeLearningContext = await youTubeContextProvider.learningContextForMostRecentPausedVideo(
                   includeFullTranscriptForSeeking: questionAsksToFindAMomentInTheVideo
               ) {
                userPromptWithVideoContext += "\n\n" + youTubeLearningContext.promptContextBlock
                if questionAsksToFindAMomentInTheVideo, youTubeLearningContext.fullTranscriptForSeekingText == nil {
                    userPromptWithVideoContext += "\n\n(they asked to find a moment in the video, but this video has no transcript, so you can't rewind it. say so in one line and use [SEEK:none].)"
                }
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
                print("📺 YouTube context: \(youTubeLearningContext.title) at \(Int(youTubeLearningContext.currentTimeSeconds))s"
                    + (youTubeLearningContext.fullTranscriptForSeekingText != nil ? " (+ full transcript for seeking)"
                       : questionAsksToFindAMomentInTheVideo ? " (rewind asked, but no transcript)" : " (last 90s only; not a rewind question)"))
            }
            guard isCurrentGeneration(pipelineGeneration) else { return }

            // Remind the tutor what this learner got stuck on before, so it
            // can connect the dots ("same idea as tuesday"). Not for review
            // answers: those are about one known concept.
            if reviewTurn == nil,
               let pastConfusionsBlock = await MemoryRecall.promptContextBlock(forQueryText: memoryRecallQueryLines.joined(separator: "\n")) {
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
            } else if let followUpQuestion {
                switch followUpQuestion.kind {
                case .prediction:
                    systemPrompt += HootTutorPrompt.predictionResolutionPromptBlock(
                        originalQuestion: followUpQuestion.subject,
                        predictionQuestion: followUpQuestion.question
                    )
                case .quickCheck:
                    systemPrompt += HootTutorPrompt.quickCheckGradingPromptBlock(
                        concept: followUpQuestion.subject,
                        checkQuestion: followUpQuestion.question
                    )
                }
            } else if isQuickCheckAfterAnswersEnabled {
                systemPrompt += HootTutorPrompt.quickChecksAlwaysOnPromptBlock
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
                    // Walkthrough: step tags come before their sentences, so
                    // resolve them before the sentence is handed to TTS.
                    self.noteWalkthroughSteps(
                        inStreamingResponse: accumulatedResponseText,
                        capturedScreens: capturedScreens,
                        startsJustDoItExecution: startsJustDoItExecution,
                        pipelineGeneration: pipelineGeneration
                    )
                    self.enqueueCompletedSentences(
                        from: accumulatedResponseText,
                        streamingSpeechState: streamingSpeechState
                    )
                }
            )
            guard isCurrentGeneration(pipelineGeneration) else { return }
            // The step list is final now (MARK: Just do it).
            justDoItSession?.hasStreamFinished = true

            // Pull out the picture request ([SKETCH:...] or [VIDEO:...]) first,
            // then the pointing tag from what is left.
            let spokenText = HootResponseTags.speakableText(from: fullResponseText)
            // Which tags came back, so a missing picture or check is diagnosable
            // from the console without reading the whole reply.
            print("🏷️ tags: \(HootResponseTags.tagNames(in: fullResponseText).joined(separator: " "))")
            let explainerVideoParseResult = HootResponseTags.parseExplainerVideoRequest(from: fullResponseText)
            let sketchParseResult = HootResponseTags.parseSketchRequest(from: explainerVideoParseResult.textWithoutVideoTag)
            let responseTextWithoutPictureTags = sketchParseResult.textWithoutSketchTag
            let recentQuestionSourceDescription = youTubeContextForExplainerVideo?.title
                ?? NSWorkspace.shared.frontmostApplication?.localizedName

            // hoot asked them something instead of (or after) answering: the
            // next hold answers it. Never chained off a graded reply.
            let isAskingForAPrediction = reviewTurn == nil && followUpQuestion == nil
                && HootResponseTags.hasPredictionTag(in: fullResponseText)
            // A quick-check answer graded with [REVIEW:]; nil ([REVIEW:none])
            // means they asked something new instead, answered normally.
            let quickCheckResult: ReviewResult? = followUpQuestion?.kind == .quickCheck
                ? HootResponseTags.parseReviewResult(from: fullResponseText)
                : nil
            let isGradedQuickCheckAnswer = quickCheckResult != nil
            // A [SEEK:] moves the video when the question asked to find a
            // moment (the tutor saw the whole transcript), or when the stamp
            // lies inside the ninety-second window the tutor was shown ("play
            // what he just said about orientation again"). Anything else is a
            // stray tag and is ignored, so an ordinary answer never jumps.
            if didPauseYouTubeVideoForThisQuestion,
               let seekTargetSeconds = HootResponseTags.parseSeekTargetSeconds(from: fullResponseText) {
                let currentVideoTimeSeconds = youTubeContextForExplainerVideo?.t ?? 0
                let isInsideShownTranscriptWindow = seekTargetSeconds >= currentVideoTimeSeconds - 95 && seekTargetSeconds <= currentVideoTimeSeconds
                if questionAsksToFindAMomentInTheVideo || isInsideShownTranscriptWindow {
                    seekTargetSecondsAfterSpeaking = seekTargetSeconds
                    print("⏪ Seek requested: \(YouTubeContextProvider.formatTimestampForTranscript(seekTargetSeconds))")
                    HootDemoLog.recordEvent("seek", YouTubeContextProvider.formatTimestampForTranscript(seekTargetSeconds))
                } else {
                    print("⏪ Seek tag ignored (question didn't ask to find a moment and the stamp is outside the shown window): \(YouTubeContextProvider.formatTimestampForTranscript(seekTargetSeconds))")
                }
            } else if questionAsksToFindAMomentInTheVideo && didPauseYouTubeVideoForThisQuestion {
                print("⏪ Rewind question, but the reply carried no usable [SEEK:] tag")
            }

            // Remember what they got stuck on (skipped for chit-chat, for a
            // guess prompt, and for graded answers).
            var rememberedEntryId: UUID?
            let conceptForThisAnswer = HootResponseTags.parseConcept(from: fullResponseText)
            if let reviewTurn {
                let reviewResult = HootResponseTags.parseReviewResult(from: fullResponseText) ?? .shaky
                MemoryStore.shared.recordReviewResult(reviewResult, forConcept: reviewTurn.concept)
                if reviewResult == .forgot {
                    savedVideoEntryToOfferAfterForgottenReview = MemoryStore.shared
                        .mostRecentEntryWithExplainerVideo(forConcept: reviewTurn.concept)
                }
            } else if let quickCheckResult, let followUpQuestion {
                MemoryStore.shared.recordReviewResult(quickCheckResult, forConcept: followUpQuestion.subject)
                print("✅ quick check on \(followUpQuestion.subject): \(quickCheckResult)")
            } else if !isAskingForAPrediction, let concept = conceptForThisAnswer {
                rememberedEntryId = MemoryStore.shared.recordAnsweredQuestion(
                    question: questionTextForRecords,
                    concept: concept,
                    answerSummary: HootResponseTags.answerSummary(fromSpokenText: spokenText),
                    sourceTitle: recentQuestionSourceDescription,
                    youTubeVideoId: youTubeContextForExplainerVideo?.videoId,
                    youTubeTimeSeconds: youTubeContextForExplainerVideo?.t
                )
            }

            // The prompt says never both; if the tutor does it anyway the sketch
            // wins, because it is on screen in seconds and the demo can't wait.
            let pictureRequest: (brief: String, kind: ExplainerKind)? = {
                if let sketchBrief = sketchParseResult.sketchBrief { return (sketchBrief, .sketch) }
                if let explainerVideoBrief = explainerVideoParseResult.explainerVideoBrief { return (explainerVideoBrief, .studioVideo) }
                return nil
            }()
            if let pictureRequest {
                print(pictureRequest.kind == .sketch ? "✏️ Sketch requested: \(pictureRequest.brief)" : "🎬 Explainer video requested: \(pictureRequest.brief)")
                didRequestExplainerVideo = true
                memoryEntryIdForMostRecentExplainerVideoRequest = rememberedEntryId
                latestExplainerVideoRequest = ExplainerVideoRequest(
                    question: questionText,
                    brief: pictureRequest.brief,
                    spokenAnswer: spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
                    youTubeContext: youTubeContextForExplainerVideo,
                    kind: pictureRequest.kind
                )
            }

            // A walkthrough's steps carry the boxes; its final tag is [POINT:none].
            if walkthroughRunner == nil,
               let pointingTarget = HootResponseTags.parsePointingTarget(from: responseTextWithoutPictureTags),
               let resolvedPointingLocation = HootResponseTags.resolvePointingTarget(pointingTarget, capturedScreens: capturedScreens) {
                // Frame and label first, so an observer of the location sees
                // all three already set.
                detectedElementDisplayFrame = resolvedPointingLocation.displayFrame
                detectedElementLabel = pointingTarget.label
                detectedElementBoxSize = resolvedPointingLocation.globalBoxSize
                // Marks share the frame's lifetime, so they are published only
                // when there is a frame for them to sit beside.
                screenAnnotations = HootResponseTags.resolveAnnotations(
                    HootResponseTags.parseAnnotations(from: explainerVideoParseResult.textWithoutVideoTag),
                    capturedScreens: capturedScreens
                )
                if !screenAnnotations.isEmpty {
                    print("✏️ Drawing \(screenAnnotations.count) mark(s) over the pointed thing")
                }
                detectedElementScreenLocation = resolvedPointingLocation.globalLocation
            }

            // MARK: - Napkin sketch
            // Drawn on screen right away, grouped by spoken sentence; the
            // pointing target is re-read here so the paper can sit beside
            // the frame without reaching into the block above.
            publishNapkinSketch(
                fromResponseText: fullResponseText,
                spokenText: spokenText,
                capturedScreens: capturedScreens,
                pointingLocation: HootResponseTags.parsePointingTarget(from: responseTextWithoutPictureTags)
                    .flatMap { HootResponseTags.resolvePointingTarget($0, capturedScreens: capturedScreens) }
            )

            // Show it under "recent" in the menu bar panel. The source is the
            // YouTube video's title when the question paused one, else the app.
            if reviewTurn == nil, !isGradedQuickCheckAnswer, !isAskingForAPrediction {
                RecentQuestionsStore.shared.recordQuestion(
                    questionText: questionTextForRecords,
                    sourceDescription: recentQuestionSourceDescription,
                    hadExplainerVideo: didRequestExplainerVideo
                )
            }

            // What hoot is now waiting on, if anything.
            if isAskingForAPrediction {
                let predictionPrompt = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !predictionPrompt.isEmpty {
                    pendingFollowUpQuestion = FollowUpQuestion(
                        kind: .prediction,
                        question: predictionPrompt,
                        subject: questionText,
                        didPauseYouTubeVideo: didPauseYouTubeVideoForThisQuestion,
                        askedDate: Date()
                    )
                    didAskAFollowUpQuestion = true
                }
            } else if reviewTurn == nil, !isGradedQuickCheckAnswer,
                      let quickCheckQuestion = HootResponseTags.parseQuickCheckQuestion(from: fullResponseText),
                      let concept = conceptForThisAnswer {
                pendingFollowUpQuestion = FollowUpQuestion(
                    kind: .quickCheck,
                    question: quickCheckQuestion,
                    subject: concept,
                    didPauseYouTubeVideo: didPauseYouTubeVideoForThisQuestion,
                    askedDate: Date()
                )
                didAskAFollowUpQuestion = true
            }

            let userTextForHistory: String
            if let reviewTurn {
                userTextForHistory = Self.userTextForReviewAnswer(questionText, reviewTurn: reviewTurn)
            } else if let followUpQuestion {
                userTextForHistory = Self.userTextForFollowUpAnswer(questionText, followUpQuestion: followUpQuestion)
            } else {
                userTextForHistory = questionText
            }
            conversationHistory.append(LLMClient.ConversationTurn(userText: userTextForHistory, assistantText: fullResponseText))
            if conversationHistory.count > Self.maximumConversationTurnsKept {
                conversationHistory.removeFirst(conversationHistory.count - Self.maximumConversationTurnsKept)
            }

            // Speak whatever is left after the last complete sentence, then
            // let the queue drain.
            // (Not after hoot stopped clicking mid-walkthrough: the rest of the
            // narration would describe clicks that won't happen.)
            if !didTextToSpeechFailBeforeAnyAudio, justDoItSession?.stopReason == nil {
                let unspokenRemainder = String(spokenText.dropFirst(streamingSpeechState.enqueuedCharacterCount))
                let stepIndexStartedByRemainder = walkthroughStepIndex(
                    forSentenceIn: streamingSpeechState.enqueuedCharacterCount..<max(spokenText.count, streamingSpeechState.enqueuedCharacterCount),
                    responseText: fullResponseText
                )
                if let stepIndexStartedByRemainder, !unspokenRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    walkthroughSentenceTextByStepIndex[stepIndexStartedByRemainder] = unspokenRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                cartesiaTTSClient.enqueueSentence(unspokenRemainder, walkthroughStepIndex: stepIndexStartedByRemainder)
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

            // Walkthrough: the steps are spoken; now watch the learner do them
            // and confirm. The pipeline stays "running" so hoot doesn't leave.
            // When hoot is clicking the steps itself there is nothing to
            // watch for: wait for its clicks instead (MARK: Just do it).
            if let justDoItSession {
                await finishJustDoItExecution(session: justDoItSession, pipelineGeneration: pipelineGeneration)
            } else if walkthroughRunner != nil {
                await runWalkthroughWatchAndConfirm(
                    question: questionText,
                    capturedScreens: capturedScreens,
                    pipelineGeneration: pipelineGeneration
                )
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
        // Walkthrough: over either way (confirmed, given up, or the answer failed).
        walkthroughRunner?.end()
        justDoItSession?.executionTask?.cancel()
        justDoItSession = nil
        voiceState = .idle
        isAnswerPipelineRunning = false
        currentAnswerTask = nil

        if let savedVideoEntryToOfferAfterForgottenReview {
            onReviewForgotWithSavedVideo?(savedVideoEntryToOfferAfterForgottenReview)
        }

        // A rewind answer jumps the video to the moment and plays it. Otherwise
        // the explainer panel resumes the video when it closes, and a
        // question hoot asked keeps it paused for the answer (abandoning the
        // question resumes it); otherwise the answer is over, so give the
        // lecture back.
        if let seekTargetSecondsAfterSpeaking {
            await youTubeContextProvider.seekVideoAndPlay(toSeconds: seekTargetSecondsAfterSpeaking)
        } else if !didRequestExplainerVideo && !didAskAFollowUpQuestion {
            await youTubeContextProvider.resumeVideoIfWePausedIt()
        }
    }

    // MARK: - Memory helpers

    /// What the tutor (and the history) sees for a spoken review answer.
    private static func userTextForReviewAnswer(_ spokenAnswer: String, reviewTurn: ReviewTurn) -> String {
        "(my answer to your quick check about \(reviewTurn.concept): \"\(reviewTurn.question)\") \(spokenAnswer)"
    }

    /// What the tutor (and the history) sees for the answer to hoot's own
    /// question: a guess, or a quick-check answer.
    private static func userTextForFollowUpAnswer(_ spokenAnswer: String, followUpQuestion: FollowUpQuestion) -> String {
        switch followUpQuestion.kind {
        case .prediction:
            return "(my guess, answering \"\(followUpQuestion.question)\". what i originally asked: \"\(followUpQuestion.subject)\") \(spokenAnswer)"
        case .quickCheck:
            return "(my answer to your quick check about \(followUpQuestion.subject): \"\(followUpQuestion.question)\") \(spokenAnswer)"
        }
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
        // Walkthrough: sentence k's clip start is what lands step k's frame.
        // When hoot clicks the steps itself, the clip start only releases
        // the executor for that step; the frame then follows the click
        // (MARK: Just do it).
        cartesiaTTSClient.onSentenceStarted = { [weak self] _, walkthroughStepIndex in
            guard let self, pipelineGeneration == self.answerGeneration, let walkthroughStepIndex else { return }
            if let justDoItSession = self.justDoItSession {
                justDoItSession.startedStepIndices.insert(walkthroughStepIndex)
            } else {
                self.walkthroughRunner?.noteSentenceStarted(forStepIndex: walkthroughStepIndex)
            }
        }
        cartesiaTTSClient.beginSpokenAnswer()
    }

    /// Hands every newly completed sentence of the streaming answer to TTS.
    /// Only text before the first tag ("[VIDEO:" / "[POINT:") is spoken.
    /// Very short sentences are held back and joined to the next one so
    /// clips aren't choppy.
    private func enqueueCompletedSentences(from accumulatedResponseText: String, streamingSpeechState: StreamingSpeechState) {
        guard !didTextToSpeechFailBeforeAnyAudio else { return }
        // Hoot stopped clicking mid-walkthrough: the rest of the narration
        // would describe clicks that won't happen (MARK: Just do it).
        if let justDoItSession, justDoItSession.stopReason != nil { return }
        // Same rule as the final text (walkthrough step tags stripped, cut at
        // the first other tag), so the enqueued count stays valid.
        let speakableText = HootResponseTags.speakableText(from: accumulatedResponseText)
        guard speakableText.count > streamingSpeechState.enqueuedCharacterCount else { return }

        let notYetEnqueuedText = speakableText.dropFirst(streamingSpeechState.enqueuedCharacterCount)
        // Walkthrough: every sentence is its own step and must start its own
        // clip, so nothing is merged ("click share." is meant to be short).
        let isWalkthrough = walkthroughRunner != nil
        let minimumSentenceLength = isWalkthrough ? 1 : 24
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
                    let sentenceStartInSpeakableText = streamingSpeechState.enqueuedCharacterCount
                    let stepIndexStartedByThisSentence = isWalkthrough
                        ? walkthroughStepIndex(
                            forSentenceIn: sentenceStartInSpeakableText..<(sentenceStartInSpeakableText + sentenceLength),
                            responseText: accumulatedResponseText
                        )
                        : nil
                    if let stepIndexStartedByThisSentence {
                        walkthroughSentenceTextByStepIndex[stepIndexStartedByThisSentence] = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    cartesiaTTSClient.enqueueSentence(sentenceText, walkthroughStepIndex: stepIndexStartedByThisSentence)
                    streamingSpeechState.enqueuedCharacterCount += sentenceLength
                    sentenceStartOffset = characterOffset
                }
            }
            previousCharacter = character
        }
    }
}
