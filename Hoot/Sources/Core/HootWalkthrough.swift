//
//  HootWalkthrough.swift
//  Hoot
//
//  Walkthrough mode (spec: docs/design/WALKTHROUGH.md). When the learner
//  asks HOW to do something on screen, the tutor answers with two to five
//  sentences, each prefixed inline by a step tag:
//
//    [STEP 1/3 POINT:x,y,w,h:share] click share.
//    [STEP 2/3 POINT:x,y,w,h:access] then switch this to anyone with the link.
//
//  This file holds the model the overlay reads (`HootWalkthroughState`), the
//  tag parsing (tolerant like `parsePointingTarget`), the runner that owns
//  the walkthrough's lifecycle (steps land as sentences start; after the
//  last one: waiting → peek → checking → done / still this one), and the
//  second LLM call that looks at a before/after screenshot pair and returns
//  a verdict.
//

import AppKit
import Foundation

// MARK: - Model

/// One step of a walkthrough, resolved to a real place on the learner's displays.
struct HootWalkthroughStep: Equatable {
    /// 1-based, for the "2 of 3" badge.
    let stepNumber: Int
    /// The tutor's short label; nil when it gave none (or "none").
    let label: String?
    /// Center of the element, AppKit global coordinates.
    let globalCenter: CGPoint
    /// The element's size in points, when the tutor boxed it.
    let globalBoxSize: CGSize?
    let displayFrame: CGRect
}

enum HootWalkthroughPhase: Equatable {
    /// Steps are being parsed out of the stream; nothing has been spoken yet.
    case gathering
    /// Step k's sentence is playing (the frame is on, or sliding to, its box).
    case step(Int)
    /// The last sentence ended: "your turn", hoot is watching.
    case waiting
    /// The 240ms look before the screenshot.
    case peek
    /// The verdict call is in flight.
    case checking
    /// Every step was done.
    case done
    /// Step k was skipped: the frame slides back to it ("still this one").
    case missed(Int)
    /// Over, one way or another; the overlay finishes its out animation.
    case ended
}

/// What the controller publishes while a walkthrough is alive.
struct HootWalkthroughState: Equatable {
    var steps: [HootWalkthroughStep]
    /// The tutor's N from "n/N" (the badge says "2 of 3" even before step 3 has streamed in).
    var totalStepCount: Int
    var phase: HootWalkthroughPhase
    /// Index into `steps` of the box the frame is on (or heading to).
    var currentStepIndex: Int
    var retryCount: Int

    var currentStep: HootWalkthroughStep? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }
}

// MARK: - Tags

/// A step tag as written by the tutor, still in screenshot pixel space.
struct HootParsedWalkthroughStep: Equatable {
    let stepNumber: Int
    let totalStepCount: Int
    let pointingTarget: HootPointingTarget
}

enum HootWalkthroughTags {
    /// `[STEP n/N POINT:x,y,w,h:label(:screenN)]`, tolerant of spaces and
    /// decimals. The two-number point form is accepted too.
    private static let stepTagPattern: String = {
        let number = #"(-?\d+(?:\.\d+)?)"#
        return #"\[\s*STEP\s*(\d+)\s*/\s*(\d+)\s+POINT\s*:\s*"# + number + #"\s*,\s*"# + number
            + #"(?:\s*,\s*"# + number + #"\s*,\s*"# + number + #")?\s*(?::([^\]]*))?\]"#
    }()

    private static let stepTagRegex = try? NSRegularExpression(pattern: stepTagPattern, options: [.caseInsensitive])

    /// Every complete step tag in the text, in order of appearance.
    static func parseSteps(from responseText: String) -> [HootParsedWalkthroughStep] {
        guard let stepTagRegex else { return [] }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)
        return stepTagRegex.matches(in: responseText, range: wholeRange).compactMap { match in
            parsedStep(from: match, in: responseText)
        }
    }

    /// Removes every complete step tag, replacing each with a single space so
    /// a sentence end glued to a tag ("share.[STEP 2/3 ...]then") still reads
    /// as a boundary. Also returns, for each removed tag, the character
    /// offset in the stripped text where that step's sentence begins. The
    /// result is prefix-stable as the stream grows, which is what lets the
    /// controller count enqueued characters against it.
    static func stripStepTags(from responseText: String) -> (strippedText: String, stepStartOffsets: [Int]) {
        guard let stepTagRegex else { return (responseText, []) }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = stepTagRegex.matches(in: responseText, range: wholeRange)
        guard !matches.isEmpty else { return (responseText, []) }

        var strippedText = ""
        var stepStartOffsets: [Int] = []
        var copyFromIndex = responseText.startIndex
        for match in matches {
            guard let tagRange = Range(match.range, in: responseText) else { continue }
            strippedText += responseText[copyFromIndex..<tagRange.lowerBound]
            strippedText += " "
            stepStartOffsets.append(strippedText.count)
            copyFromIndex = tagRange.upperBound
        }
        strippedText += responseText[copyFromIndex...]
        return (strippedText, stepStartOffsets)
    }

    /// True once the stream carries at least one complete step tag.
    static func containsStepTag(_ responseText: String) -> Bool {
        guard let stepTagRegex else { return false }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)
        return stepTagRegex.firstMatch(in: responseText, range: wholeRange) != nil
    }

    /// Which step (index into `stepStartOffsets`) a sentence spanning
    /// `sentenceRange` of the stripped text starts: the step whose sentence
    /// begins inside it. nil when the sentence is a continuation.
    static func stepIndex(startedBySentenceIn sentenceRange: Range<Int>, stepStartOffsets: [Int]) -> Int? {
        stepStartOffsets.firstIndex { sentenceRange.contains($0) }
    }

    private static func parsedStep(from match: NSTextCheckingResult, in responseText: String) -> HootParsedWalkthroughStep? {
        guard let stepNumberRange = Range(match.range(at: 1), in: responseText),
              let totalRange = Range(match.range(at: 2), in: responseText),
              let stepNumber = Int(responseText[stepNumberRange]),
              let totalStepCount = Int(responseText[totalRange]),
              let xRange = Range(match.range(at: 3), in: responseText),
              let yRange = Range(match.range(at: 4), in: responseText),
              let firstNumber = Double(responseText[xRange]),
              let secondNumber = Double(responseText[yRange]) else { return nil }

        var pixelX = firstNumber
        var pixelY = secondNumber
        var pixelWidth: Double?
        var pixelHeight: Double?
        if let widthRange = Range(match.range(at: 5), in: responseText),
           let heightRange = Range(match.range(at: 6), in: responseText),
           let boxWidth = Double(responseText[widthRange]),
           let boxHeight = Double(responseText[heightRange]),
           boxWidth > 0, boxHeight > 0 {
            pixelWidth = boxWidth
            pixelHeight = boxHeight
            pixelX = firstNumber + boxWidth / 2
            pixelY = secondNumber + boxHeight / 2
        }

        var label: String?
        var screenNumber: Int?
        if let labelAndScreenRange = Range(match.range(at: 7), in: responseText) {
            var labelComponents = responseText[labelAndScreenRange]
                .split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let lastComponent = labelComponents.last?.lowercased(),
               lastComponent.hasPrefix("screen"),
               let parsedScreenNumber = Int(lastComponent.dropFirst("screen".count).trimmingCharacters(in: .whitespaces)) {
                screenNumber = parsedScreenNumber
                labelComponents.removeLast()
            }
            let joinedLabel = labelComponents.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            label = (joinedLabel.isEmpty || joinedLabel.lowercased() == "none" || joinedLabel.lowercased() == "nil") ? nil : joinedLabel
        }

        return HootParsedWalkthroughStep(
            stepNumber: stepNumber,
            totalStepCount: totalStepCount,
            pointingTarget: HootPointingTarget(
                pixelX: pixelX,
                pixelY: pixelY,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                label: label,
                screenNumber: screenNumber
            )
        )
    }
}

// MARK: - Verdict call

enum HootWalkthroughVerdict: Equatable {
    case done
    /// 0-based index of the earliest step not done.
    case missed(stepIndex: Int)
}

enum HootWalkthroughConfirmation {
    static let systemPrompt = """
    you're a tiny pixel-art study buddy. you walked the learner through a few steps on their screen, then waited while they did them. you get two screenshots: BEFORE (when you gave the steps) and AFTER (now), plus the list of steps and the box you framed for each.
    decide whether the learner has done all the steps. be lenient: if the AFTER screenshot is consistent with the steps being done (a dialog closed, a toast, a changed setting, the next screen), count it as done. if you genuinely can't tell either way, count it as done.
    reply with exactly one short sentence to be spoken aloud, all lowercase, no markdown, no symbols, no praise words, then one tag: [VERDICT:done] when everything is done, or [VERDICT:missed:k] where k is the number of the earliest step that still isn't done.
    for done, the sentence is a plain confirmation of the result ("nice, the link's copied."). for missed, the sentence says what to do for that one step ("the access menu is still on restricted, switch it to anyone with the link."). never mention screenshots, coordinates or boxes.
    """

    /// The user turn for the verdict call: before image, after image, the
    /// steps, the question. Same content-block shape as the tutor call.
    static func userContentBlocks(
        question: String,
        steps: [HootWalkthroughStep],
        beforeScreen: CapturedScreen,
        afterScreen: CapturedScreen
    ) -> [[String: Any]] {
        func imageBlock(_ screen: CapturedScreen) -> [String: Any] {
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": screen.jpegImageData.base64EncodedString(),
                ],
            ]
        }
        let stepLines = steps.map { step in
            "step \(step.stepNumber): \(step.label ?? "(no label)")"
        }
        return [
            imageBlock(beforeScreen),
            ["type": "text", "text": "BEFORE: the screen when you gave the steps (\(beforeScreen.imageWidthInPixels)x\(beforeScreen.imageHeightInPixels) pixels)."],
            imageBlock(afterScreen),
            ["type": "text", "text": "AFTER: the screen now (\(afterScreen.imageWidthInPixels)x\(afterScreen.imageHeightInPixels) pixels)."],
            ["type": "text", "text": "the learner asked: \"\(question)\"\nthe steps you gave:\n" + stepLines.joined(separator: "\n")],
        ]
    }

    /// `[VERDICT:done]` / `[VERDICT:missed:k]` plus the sentence before it.
    /// A missing or unreadable tag counts as done, which is the lenient
    /// reading the prompt asks for anyway.
    static func parseVerdict(from responseText: String, stepCount: Int) -> (verdict: HootWalkthroughVerdict, spokenSentence: String) {
        let spokenSentence = HootResponseTags.speakableText(from: responseText).trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\[VERDICT\s*:\s*(done|missed)(?:\s*:\s*(\d+))?\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let kindRange = Range(match.range(at: 1), in: responseText) else {
            return (.done, spokenSentence)
        }
        if responseText[kindRange].lowercased() == "missed",
           let numberRange = Range(match.range(at: 2), in: responseText),
           let stepNumber = Int(responseText[numberRange]),
           stepNumber >= 1, stepNumber <= stepCount {
            return (.missed(stepIndex: stepNumber - 1), spokenSentence)
        }
        return (.done, spokenSentence)
    }
}

// MARK: - Runner

/// Owns one walkthrough from the first parsed step to the end. The
/// controller feeds it (steps as they stream in, sentence starts from TTS)
/// and awaits `runWatchAndConfirm` after the last sentence; every change is
/// published back through `onStateChange` so the overlay can draw it.
@MainActor
final class HootWalkthroughRunner {
    /// After the last sentence, how long hoot watches before it looks.
    static let secondsToWaitForTheLearner: TimeInterval = 4
    /// A click inside the current box brings the look forward to this soon after.
    static let secondsAfterClickInsideBoxBeforePeek: TimeInterval = 0.3
    static let peekDurationInSeconds: TimeInterval = 0.24
    static let maximumRetryCount = 2

    private(set) var state: HootWalkthroughState {
        didSet { if state != oldValue { onStateChange(state) } }
    }
    private let onStateChange: (HootWalkthroughState) -> Void
    /// How many step tags of the stream the controller has already turned
    /// into steps (kept here so a tag that failed to resolve is never retried
    /// and the ones after it are never appended twice).
    var handledParsedStepCount = 0
    private var clickMonitor: Any?
    private var dateOfLastClickInsideCurrentBox: Date?

    init(totalStepCount: Int, onStateChange: @escaping (HootWalkthroughState) -> Void) {
        self.onStateChange = onStateChange
        state = HootWalkthroughState(
            steps: [],
            totalStepCount: max(totalStepCount, 1),
            phase: .gathering,
            currentStepIndex: 0,
            retryCount: 0
        )
        onStateChange(state)
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// New steps from the stream (already resolved to global coordinates).
    func appendSteps(_ newSteps: [HootWalkthroughStep], totalStepCount: Int) {
        guard !newSteps.isEmpty else { return }
        var updatedState = state
        updatedState.steps.append(contentsOf: newSteps)
        updatedState.totalStepCount = max(totalStepCount, updatedState.steps.count, 1)
        state = updatedState
    }

    var hasSteps: Bool { !state.steps.isEmpty }

    /// TTS started the sentence that carries step `stepIndex`: the frame
    /// moves on the sentence boundary, never on a click.
    func noteSentenceStarted(forStepIndex stepIndex: Int) {
        guard state.steps.indices.contains(stepIndex) else { return }
        var updatedState = state
        updatedState.currentStepIndex = stepIndex
        updatedState.phase = .step(stepIndex)
        state = updatedState
    }

    /// Ends the walkthrough wherever it is (a new question, an error).
    func end() {
        stopWatchingForClicks()
        guard state.phase != .ended else { return }
        var updatedState = state
        updatedState.phase = .ended
        state = updatedState
    }

    /// After the last sentence: wait for the learner, look, ask the model
    /// whether the steps got done, and either celebrate or slide back to
    /// the missed step and wait again (at most two retries). `speak` returns
    /// once its sentence has been heard; `isCancelled` is polled throughout
    /// so a new ⌃⌥ hold ends everything promptly.
    func runWatchAndConfirm(
        question: String,
        beforeScreens: [CapturedScreen],
        llmClient: LLMClient,
        speak: @escaping (String) async -> Void,
        isCancelled: @escaping () -> Bool
    ) async {
        guard hasSteps, state.phase != .ended else { return }
        defer { stopWatchingForClicks() }

        while !isCancelled() {
            setPhase(.waiting)
            await waitForTheLearner(isCancelled: isCancelled)
            if isCancelled() { return }

            setPhase(.peek)
            // The screenshot is taken after the fill flash so it isn't in the image.
            try? await Task.sleep(nanoseconds: UInt64(Self.peekDurationInSeconds * 1_000_000_000))
            if isCancelled() { return }

            setPhase(.checking)
            let verdictAndSentence: (verdict: HootWalkthroughVerdict, spokenSentence: String)
            do {
                verdictAndSentence = try await requestVerdict(
                    question: question,
                    beforeScreens: beforeScreens,
                    llmClient: llmClient
                )
            } catch {
                NSLog("⚠️ walkthrough verdict error: %@", String(describing: error))
                end()
                return
            }
            if isCancelled() { return }

            switch verdictAndSentence.verdict {
            case .done:
                setPhase(.done)
                if !verdictAndSentence.spokenSentence.isEmpty {
                    await speak(verdictAndSentence.spokenSentence)
                }
                end()
                return
            case .missed(let missedStepIndex):
                var updatedState = state
                updatedState.retryCount += 1
                if updatedState.retryCount > Self.maximumRetryCount {
                    // Second miss: the frame goes out and the tutor takes over in voice.
                    updatedState.phase = .ended
                    state = updatedState
                    stopWatchingForClicks()
                    if !verdictAndSentence.spokenSentence.isEmpty {
                        await speak(verdictAndSentence.spokenSentence)
                    }
                    return
                }
                updatedState.currentStepIndex = missedStepIndex
                updatedState.phase = .missed(missedStepIndex)
                state = updatedState
                if !verdictAndSentence.spokenSentence.isEmpty {
                    await speak(verdictAndSentence.spokenSentence)
                }
                // Back to waiting on the missed step's box.
            }
        }
    }

    // MARK: Waiting

    private func waitForTheLearner(isCancelled: () -> Bool) async {
        startWatchingForClicks()
        dateOfLastClickInsideCurrentBox = nil
        let waitingStartDate = Date()
        while !isCancelled() {
            let now = Date()
            if now.timeIntervalSince(waitingStartDate) >= Self.secondsToWaitForTheLearner { break }
            if let dateOfLastClickInsideCurrentBox,
               now.timeIntervalSince(dateOfLastClickInsideCurrentBox) >= Self.secondsAfterClickInsideBoxBeforePeek {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        stopWatchingForClicks()
    }

    /// A global mouse-down monitor is cheap and needs no extra permission;
    /// a click inside the current box brings the look forward.
    private func startWatchingForClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let currentBoxRect = self.currentBoxRectInGlobalSpace else { return }
                if currentBoxRect.contains(NSEvent.mouseLocation) {
                    self.dateOfLastClickInsideCurrentBox = Date()
                }
            }
        }
    }

    private func stopWatchingForClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// The current step's element box (plus the frame padding), global coordinates.
    private var currentBoxRectInGlobalSpace: CGRect? {
        guard let currentStep = state.currentStep else { return nil }
        let boxSize = currentStep.globalBoxSize ?? CGSize(width: 64, height: 40)
        let padding: CGFloat = 4
        return CGRect(
            x: currentStep.globalCenter.x - boxSize.width / 2 - padding,
            y: currentStep.globalCenter.y - boxSize.height / 2 - padding,
            width: boxSize.width + padding * 2,
            height: boxSize.height + padding * 2
        )
    }

    // MARK: Verdict

    private func requestVerdict(
        question: String,
        beforeScreens: [CapturedScreen],
        llmClient: LLMClient
    ) async throws -> (verdict: HootWalkthroughVerdict, spokenSentence: String) {
        let targetDisplayFrame = state.currentStep?.displayFrame
        let beforeScreen = beforeScreens.first { $0.displayFrame == targetDisplayFrame }
            ?? beforeScreens.first { $0.isCursorScreen }
            ?? beforeScreens[0]
        let afterScreens = try await ScreenCapturer.captureAllScreens()
        let afterScreen = afterScreens.first { $0.displayFrame == beforeScreen.displayFrame }
            ?? afterScreens.first { $0.isCursorScreen }
            ?? afterScreens[0]

        let responseText = try await llmClient.requestCompleteAnswer(
            systemPrompt: HootWalkthroughConfirmation.systemPrompt,
            userContentBlocks: HootWalkthroughConfirmation.userContentBlocks(
                question: question,
                steps: state.steps,
                beforeScreen: beforeScreen,
                afterScreen: afterScreen
            )
        )
        print("👀 walkthrough verdict: \(responseText)")
        return HootWalkthroughConfirmation.parseVerdict(from: responseText, stepCount: state.steps.count)
    }

    private func setPhase(_ phase: HootWalkthroughPhase) {
        var updatedState = state
        updatedState.phase = phase
        state = updatedState
    }
}
