//
//  PetOverlayCoordinator.swift
//  Hoot
//
//  The one hoot on screen and its "corner home + cursor head" loop
//  (design 4a). There is one overlay window per display, but a single
//  coordinator: it owns hoot's position in AppKit global coordinates, so
//  hoot can fly between monitors and every screen's view simply draws
//  whatever falls inside its own frame.
//
//    home ──⌃⌥──▶ flyingToCursor ─▶ atCursor ──[POINT]──▶ flyingToTarget
//      ▲                               │  ▲                     │
//      │                         done  │  └─ flyingBackToCursor ◀─ pointingAtTarget
//      │                               ▼
//      └── flyingHome / fadingOut ◀── lingering (3s, ⌃⌥ again = follow up)
//
//  The head rides the cursor only while ⌃⌥ is held; from thinking on it
//  parks where the hold ended (see `parkedHeadCenterInGlobalSpace`).
//
//  A single 60Hz frame tick drives everything (cursor following, flights,
//  polling `isSpeakingResponseAloud`, which isn't published), so the state
//  machine never depends on the order Combine delivers changes in.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PetOverlayCoordinator: ObservableObject {
    enum Phase: Equatable {
        /// The full 48pt hoot dozing in the corner (or hidden there).
        case home
        /// Zipping from the corner (or back from a flight home) to the cursor.
        case flyingToCursor
        /// Riding beside the cursor while listening, thinking and talking.
        case atCursor
        /// Arcing to a [POINT:] target.
        case flyingToTarget
        /// Beside the ringed target until the answer has been spoken.
        case pointingAtTarget
        /// Arcing back to the cursor after pointing.
        case flyingBackToCursor
        /// The 3s follow-up window by the cursor.
        case lingering
        /// Flying back to the corner, where it grows into the full hoot.
        case flyingHome
        /// No corner hoot to go back to: the head fades out where it is.
        case fadingOut
    }

    // MARK: Published state for the screen views

    @Published private(set) var phase: Phase = .home
    /// Center of hoot (full body or head), AppKit global coordinates.
    @Published private(set) var petCenterInGlobalSpace: CGPoint
    @Published private(set) var isPetDrawnAsFullBody = true
    /// Pops the head in at the cursor and grows the head into the full hoot on landing.
    @Published private(set) var petGrowScale: CGFloat = 1
    /// Fades the head out when a session ends with no corner hoot to fly to.
    @Published private(set) var petSessionOpacity: Double = 1
    /// Right after landing home hoot looks around for a moment before dozing off.
    @Published private(set) var isFullBodyAwakeAfterLanding = false
    @Published private(set) var isFrontmostAppFullscreenOnPrimaryScreen = false
    /// Mirrors `hootController.isSpeakingResponseAloud` (polled every frame).
    @Published private(set) var isResponseAudioPlaying = false

    /// Every position of the current / last flight, oldest first, for the trail.
    @Published private(set) var flightTrailPositionsInGlobalSpace: [CGPoint] = []
    @Published private(set) var flightTrailOpacity: Double = 0

    @Published private(set) var pointingTargetInGlobalSpace: CGPoint?
    @Published private(set) var isPointingRingShown = false
    /// Index-card frame motion (POINTING.md): 0…1 in 8 steps over 240ms.
    @Published private(set) var pointingFrameDrawProgress: CGFloat = 0
    @Published private(set) var pointingFrameOpacity: Double = 0
    @Published private(set) var pointingTabRiseOffset: CGFloat = 4
    @Published private(set) var pointingTabOpacity: Double = 0
    private var pointingFrameAnimationTask: Task<Void, Never>?

    @Published private(set) var lingerStartDate = Date()

    // MARK: Tuning

    static let fullBodySideLength: CGFloat = 48
    static let headSideLength: CGFloat = 24
    /// Much longer when hoot asked them something: the question stays on
    /// screen (sticky) until it is answered or a minute passes.
    var lingerDurationInSeconds: TimeInterval {
        isWaitingForAnAnswer ? 60 : 3
    }

    /// hoot ended its reply with a question the next hold answers.
    var isWaitingForAnAnswer: Bool {
        hootController.pendingFollowUpQuestion != nil
    }

    /// Head center relative to the cursor tip, in SwiftUI terms (+x right,
    /// +y down): just below-right of the arrow, as in the 4a mock.
    private static let headOffsetFromCursorInSwiftUISpace = CGSize(width: 36, height: 32)

    /// The zip from the corner to the cursor (design: ≤150ms).
    private let flightToCursorDurationInSeconds: TimeInterval = 0.15
    /// Moving the cursor faster than this during the linger skips it.
    private let cursorSpeedThatSkipsLingerInPointsPerSecond: CGFloat = 2200
    /// How long hoot must stay idle before the answer counts as finished.
    /// Rides over the short gap between key-up and the pipeline starting,
    /// and between spoken sentences.
    private let quietSecondsBeforeAnswerCountsAsFinished: TimeInterval = 0.7
    private let minimumPointingSeconds: TimeInterval = 3
    private let maximumPointingSeconds: TimeInterval = 25

    // MARK: Private state

    private let hootController: HootController
    private var frameTimer: Timer?
    private var activeFlight: PetFlight?
    private var hootQuietSinceDate: Date?
    private var pointingStartDate = Date()

    /// Edge detection, so a stale state (e.g. a leftover `.processing`) can
    /// never restart a session on its own: only fresh transitions do.
    private var previousVoiceState: HootController.VoiceState = .idle
    private var wasAnswerPipelineRunning = false
    private var lastHandledDetectedElementLocation: CGPoint?

    private var previousCursorLocation = NSEvent.mouseLocation
    private var previousFrameDate = Date()
    private var lastFullscreenCheckDate = Date.distantPast

    /// Where the head parked once the hold ended. hoot rides the cursor only
    /// while listening; through thinking, talking and the follow-up window it
    /// stays put, so the answer bubble doesn't chase the mouse across the
    /// screen (or across a window switch). nil while following the cursor.
    private var parkedHeadCenterInGlobalSpace: CGPoint?
    /// A new hold from farther than this flies hoot back over to the cursor.
    private let distanceFromCursorThatTriggersFlightBack: CGFloat = 48

    init(hootController: HootController) {
        self.hootController = hootController
        self.petCenterInGlobalSpace = Self.homeCenterInGlobalSpace()
    }

    // MARK: - Derived state (read by the screen views)

    /// The corner hoot shows when "always visible" is on, and gets out of the
    /// way of fullscreen apps and the explainer video (whose panel shows its
    /// own perched hoot).
    var isCornerHootAllowed: Bool {
        hootController.isCornerPetEnabled
            && !hootController.isExplainerVideoPlaying
            && !isFrontmostAppFullscreenOnPrimaryScreen
    }

    var isPetVisible: Bool {
        phase == .home ? isCornerHootAllowed : true
    }

    var isPetFlying: Bool {
        activeFlight != nil
    }

    /// Full body at home: dozing (the `presenting` frames), awake for a
    /// moment right after landing.
    var fullBodyAnimationState: PetAnimationState {
        // Waves while a corner nudge is up (PetOverlayManager re-renders on change).
        if NudgeCenter.shared.currentNudge != nil { return .hello }
        return isFullBodyAwakeAfterLanding ? .idle : .presenting
    }

    /// The head listens while ⌃⌥ is held, darts its eyes while thinking,
    /// talks while the answer plays and reaches out while pointing (only the
    /// full-body mascots have that pose; hoot's head sprite falls back to idle).
    var headAnimationState: PetAnimationState {
        switch phase {
        case .flyingToTarget, .pointingAtTarget:
            return isResponseAudioPlaying ? .talking : .pointing
        case .lingering, .flyingHome, .fadingOut, .home:
            return .idle
        case .flyingToCursor, .atCursor, .flyingBackToCursor:
            break
        }
        switch hootController.voiceState {
        case .listening:
            return .listening
        case .processing:
            return isResponseAudioPlaying ? .talking : .thinking
        case .responding:
            return .talking
        case .idle:
            return isResponseAudioPlaying ? .talking : .idle
        }
    }

    /// Mirror the head so it faces a target to its left.
    var isHeadMirroredTowardTarget: Bool {
        guard phase == .flyingToTarget || phase == .pointingAtTarget,
              let pointingTargetInGlobalSpace else { return false }
        return pointingTargetInGlobalSpace.x < petCenterInGlobalSpace.x
    }

    // MARK: - Lifecycle

    func startFrameTicks() {
        guard frameTimer == nil else { return }
        returnHomeImmediately()
        previousVoiceState = hootController.voiceState
        wasAnswerPipelineRunning = hootController.isAnswerPipelineRunning
        lastHandledDetectedElementLocation = hootController.detectedElementScreenLocation

        let newFrameTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleFrameTick()
            }
        }
        // .common so hoot keeps moving while a menu is open or a drag is tracking.
        RunLoop.main.add(newFrameTimer, forMode: .common)
        frameTimer = newFrameTimer
    }

    func stopFrameTicks() {
        frameTimer?.invalidate()
        frameTimer = nil
        activeFlight = nil
    }

    // MARK: - Frame tick

    private func handleFrameTick() {
        let now = Date()
        let cursorLocation = NSEvent.mouseLocation

        let isSpeakingNow = hootController.isSpeakingResponseAloud
        if isSpeakingNow != isResponseAudioPlaying {
            isResponseAudioPlaying = isSpeakingNow
        }
        refreshFullscreenStateAboutOncePerSecond(now: now)

        let secondsSincePreviousFrame = max(now.timeIntervalSince(previousFrameDate), 0.001)
        let cursorSpeedInPointsPerSecond = hypot(
            cursorLocation.x - previousCursorLocation.x,
            cursorLocation.y - previousCursorLocation.y
        ) / CGFloat(secondsSincePreviousFrame)
        previousCursorLocation = cursorLocation
        previousFrameDate = now

        // Fresh activity: a new recording or a new answer starting.
        let currentVoiceState = hootController.voiceState
        let isAnswerPipelineRunningNow = hootController.isAnswerPipelineRunning
        let didStartListening = currentVoiceState == .listening && previousVoiceState != .listening
        let didStartAnswerPipeline = isAnswerPipelineRunningNow && !wasAnswerPipelineRunning
        previousVoiceState = currentVoiceState
        wasAnswerPipelineRunning = isAnswerPipelineRunningNow
        if didStartListening || didStartAnswerPipeline {
            handleNewQuestionActivity(isNewRecording: didStartListening, cursorLocation: cursorLocation)
        }

        handleDetectedElementLocationIfChanged(cursorLocation: cursorLocation)

        advanceActiveFlight(now: now, cursorLocation: cursorLocation)

        switch phase {
        case .home:
            keepCornerHootInPlace()
        case .atCursor:
            followCursorWhileListeningElsePark(cursorLocation: cursorLocation)
            startLingeringIfHootIsDone(now: now)
        case .lingering:
            followCursorWhileListeningElsePark(cursorLocation: cursorLocation)
            if isHootBusyAnswering {
                // A follow-up (or late audio) keeps hoot at the cursor.
                hootQuietSinceDate = nil
                phase = .atCursor
            } else {
                let hasLingerTimedOut = now.timeIntervalSince(lingerStartDate) >= lingerDurationInSeconds
                // A flick of the mouse skips an ordinary follow-up window, but
                // never drops a question hoot is waiting on.
                let isLearnerMovingAwayFast = !isWaitingForAnAnswer
                    && cursorSpeedInPointsPerSecond > cursorSpeedThatSkipsLingerInPointsPerSecond
                if hasLingerTimedOut || isLearnerMovingAwayFast {
                    endCursorSession()
                }
            }
        case .pointingAtTarget:
            let secondsSpentPointing = now.timeIntervalSince(pointingStartDate)
            let hasPointedLongEnough = secondsSpentPointing >= minimumPointingSeconds
                && (!isResponseAudioPlaying || secondsSpentPointing >= maximumPointingSeconds)
            if hasPointedLongEnough {
                flyBackToCursorAfterPointing()
            }
        case .flyingToCursor, .flyingToTarget, .flyingBackToCursor, .flyingHome, .fadingOut:
            break
        }
    }

    /// Recording, waiting on / streaming the answer, speaking, or pointing.
    /// voiceState alone is deliberately not trusted: a stale `.processing`
    /// once pinned hoot (and its bubble) to the cursor forever.
    private var isHootBusyAnswering: Bool {
        hootController.voiceState == .listening
            || hootController.isAnswerPipelineRunning
            || isResponseAudioPlaying
            || hootController.detectedElementScreenLocation != nil
    }

    private func startLingeringIfHootIsDone(now: Date) {
        if isHootBusyAnswering {
            hootQuietSinceDate = nil
            return
        }
        guard let hootQuietSinceDate else {
            hootQuietSinceDate = now
            return
        }
        if now.timeIntervalSince(hootQuietSinceDate) >= quietSecondsBeforeAnswerCountsAsFinished {
            self.hootQuietSinceDate = nil
            lingerStartDate = now
            phase = .lingering
        }
    }

    private func refreshFullscreenStateAboutOncePerSecond(now: Date) {
        guard now.timeIntervalSince(lastFullscreenCheckDate) >= 1 else { return }
        lastFullscreenCheckDate = now
        guard let primaryScreenFrame = NSScreen.screens.first?.frame else { return }
        let isFullscreenNow = FullscreenAppDetector.isFrontmostApplicationFullscreen(onScreenFrame: primaryScreenFrame)
        if isFullscreenNow != isFrontmostAppFullscreenOnPrimaryScreen {
            isFrontmostAppFullscreenOnPrimaryScreen = isFullscreenNow
        }
    }

    // MARK: - Positions

    /// Where hoot dozes: the bottom-right corner, or wherever it was dragged.
    static func homeCenterInGlobalSpace() -> CGPoint {
        PetHomeSpot.homeCenterInGlobalSpace()
    }

    private func headCenterBesideCursor(cursorLocation: CGPoint) -> CGPoint {
        // Global space has +y up, so "below the cursor" subtracts.
        CGPoint(
            x: cursorLocation.x + Self.headOffsetFromCursorInSwiftUISpace.width,
            y: cursorLocation.y - Self.headOffsetFromCursorInSwiftUISpace.height
        )
    }

    private func followCursor(cursorLocation: CGPoint) {
        let headCenter = headCenterBesideCursor(cursorLocation: cursorLocation)
        if headCenter != petCenterInGlobalSpace {
            petCenterInGlobalSpace = headCenter
        }
    }

    /// Design 4a's cursor-riding is for the ask: the head follows while ⌃⌥
    /// is held and parks where it is the moment the hold ends.
    private func followCursorWhileListeningElsePark(cursorLocation: CGPoint) {
        if hootController.voiceState == .listening {
            parkedHeadCenterInGlobalSpace = nil
            followCursor(cursorLocation: cursorLocation)
        } else if parkedHeadCenterInGlobalSpace == nil {
            parkedHeadCenterInGlobalSpace = petCenterInGlobalSpace
        }
    }

    /// A new hold while parked: start following again, flying over first if
    /// the cursor has wandered off so the head never teleports.
    private func leaveParkingSpotForCursor(cursorLocation: CGPoint) {
        guard parkedHeadCenterInGlobalSpace != nil else { return }
        parkedHeadCenterInGlobalSpace = nil
        let cursorHeadSpot = headCenterBesideCursor(cursorLocation: cursorLocation)
        let distanceToCursorHeadSpot = hypot(cursorHeadSpot.x - petCenterInGlobalSpace.x, cursorHeadSpot.y - petCenterInGlobalSpace.y)
        if distanceToCursorHeadSpot > distanceFromCursorThatTriggersFlightBack {
            flyToCursor()
        }
    }

    /// The Dock or the display arrangement can change while hoot dozes.
    private func keepCornerHootInPlace() {
        guard activeFlight == nil else { return }
        let homeCenter = Self.homeCenterInGlobalSpace()
        if homeCenter != petCenterInGlobalSpace {
            petCenterInGlobalSpace = homeCenter
        }
    }

    // MARK: - Asking

    private func handleNewQuestionActivity(isNewRecording: Bool, cursorLocation: CGPoint) {
        switch phase {
        case .home:
            startCursorSession(cursorLocation: cursorLocation)
        case .lingering:
            hootQuietSinceDate = nil
            phase = .atCursor
            if isNewRecording {
                leaveParkingSpotForCursor(cursorLocation: cursorLocation)
            }
        case .atCursor:
            if isNewRecording {
                leaveParkingSpotForCursor(cursorLocation: cursorLocation)
            }
        case .flyingHome, .fadingOut:
            // Asked again on the way out: turn around.
            flyToCursor()
        case .flyingToTarget, .pointingAtTarget:
            // A new question while pointing: come back to the cursor now.
            if isNewRecording {
                parkedHeadCenterInGlobalSpace = nil
                flyBackToCursorAfterPointing()
            }
        case .flyingToCursor, .flyingBackToCursor:
            break
        }
    }

    /// ⌃⌥ was pressed. From a visible corner hoot, it shrinks into the head
    /// and zips over; otherwise the head pops in right at the cursor.
    private func startCursorSession(cursorLocation: CGPoint) {
        hootQuietSinceDate = nil
        parkedHeadCenterInGlobalSpace = nil
        isFullBodyAwakeAfterLanding = false

        if isCornerHootAllowed {
            flyToCursor()
        } else {
            popHeadInAtCursor(cursorLocation: cursorLocation)
        }
    }

    private func popHeadInAtCursor(cursorLocation: CGPoint) {
        // A jump, not a move: no spring may carry the head over from the corner.
        changeWithoutAnimation {
            activeFlight = nil
            isPetDrawnAsFullBody = false
            petSessionOpacity = 1
            petCenterInGlobalSpace = headCenterBesideCursor(cursorLocation: cursorLocation)
            phase = .atCursor
            petGrowScale = 0.4
        }
        // Next runloop turn, so SwiftUI sees 0.4 first and springs up from it.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                self.petGrowScale = 1
            }
        }
    }

    private func flyToCursor() {
        hootQuietSinceDate = nil
        parkedHeadCenterInGlobalSpace = nil
        isPetDrawnAsFullBody = false
        petGrowScale = 1
        if petSessionOpacity < 1 {
            withAnimation(.easeOut(duration: 0.12)) {
                petSessionOpacity = 1
            }
        }
        phase = .flyingToCursor
        startFlight(destination: .headSpotBesideCursor, durationInSeconds: flightToCursorDurationInSeconds) { [weak self] in
            guard let self, self.phase == .flyingToCursor else { return }
            self.phase = .atCursor
        }
    }

    // MARK: - Going home

    /// The answer is done and the follow-up window passed: fly home and grow
    /// back into the full hoot, or fade the head out if there is no corner
    /// hoot to go back to.
    private func endCursorSession() {
        hootQuietSinceDate = nil
        // Leaving without an answer drops hoot's open question.
        hootController.abandonPendingFollowUpQuestion()

        guard isCornerHootAllowed else {
            phase = .fadingOut
            withAnimation(.easeOut(duration: 0.25)) {
                petSessionOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // Asked again while fading: hoot is already headed back to the cursor.
                guard let self, self.phase == .fadingOut else { return }
                self.returnHomeImmediately()
            }
            return
        }

        phase = .flyingHome
        let homeCenter = Self.homeCenterInGlobalSpace()
        let flightDistance = hypot(homeCenter.x - petCenterInGlobalSpace.x, homeCenter.y - petCenterInGlobalSpace.y)
        let flightDuration = min(max(flightDistance / 1300, 0.3), 0.6)
        startFlight(destination: .fixedPoint(homeCenter), durationInSeconds: flightDuration) { [weak self] in
            guard let self, self.phase == .flyingHome else { return }
            self.landInTheCorner()
        }
    }

    private func landInTheCorner() {
        phase = .home
        parkedHeadCenterInGlobalSpace = nil
        isPetDrawnAsFullBody = true
        // The 24pt head is half the 48pt body, so grow from 0.5.
        petGrowScale = 0.5
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                self.petGrowScale = 1
            }
        }
        isFullBodyAwakeAfterLanding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.phase == .home else { return }
            self.isFullBodyAwakeAfterLanding = false
        }
    }

    private func returnHomeImmediately() {
        changeWithoutAnimation {
            activeFlight = nil
            parkedHeadCenterInGlobalSpace = nil
            phase = .home
            isPetDrawnAsFullBody = true
            petGrowScale = 1
            petCenterInGlobalSpace = Self.homeCenterInGlobalSpace()
            petSessionOpacity = 1
            isFullBodyAwakeAfterLanding = false
            pointingTargetInGlobalSpace = nil
            isPointingRingShown = false
            pointingFrameAnimationTask?.cancel()
            pointingFrameOpacity = 0
        }
    }

    /// Applies changes that are jumps (teleports, resets) with the views'
    /// implicit `.animation` modifiers switched off.
    private func changeWithoutAnimation(_ changes: () -> Void) {
        var jumpTransaction = Transaction()
        jumpTransaction.disablesAnimations = true
        withTransaction(jumpTransaction, changes)
    }

    // MARK: - Pointing

    private func handleDetectedElementLocationIfChanged(cursorLocation: CGPoint) {
        let detectedElementLocation = hootController.detectedElementScreenLocation
        guard detectedElementLocation != lastHandledDetectedElementLocation else { return }
        lastHandledDetectedElementLocation = detectedElementLocation
        guard let detectedElementLocation else { return }
        flyToPointingTarget(targetInGlobalSpace: detectedElementLocation, cursorLocation: cursorLocation)
    }

    /// Arcs the head to sit just beside the target's ring (right of it unless
    /// that leaves the display) and rings the target once it lands.
    private func flyToPointingTarget(targetInGlobalSpace: CGPoint, cursorLocation: CGPoint) {
        if phase == .home {
            // Pointing without a question in flight (unusual): leave the corner
            // from where hoot is, or pop in at the cursor if it was hidden.
            if isCornerHootAllowed {
                isPetDrawnAsFullBody = false
                petGrowScale = 1
                petSessionOpacity = 1
            } else {
                popHeadInAtCursor(cursorLocation: cursorLocation)
            }
        } else if phase == .fadingOut {
            withAnimation(.easeOut(duration: 0.12)) {
                petSessionOpacity = 1
            }
        }

        let targetDisplayFrame = hootController.detectedElementDisplayFrame
            ?? PetOverlayCoordinateSpace.screenFrame(containingGlobalPoint: targetInGlobalSpace)
            ?? NSScreen.screens.first?.frame
            ?? .zero
        let headHalfSide = Self.headSideLength / 2
        // Land beside the index-card frame (POINTING.md): 10pt outside it,
        // past the depth edge, on the side nearer the cursor, with the head's
        // top 8pt below the frame's top. Global space has +y up.
        let pointingFrameSize = PetPointingFrameView.paddedFrameSize(
            forElementSize: hootController.detectedElementBoxSize,
            screenSize: targetDisplayFrame.size
        )
        let frameHalfWidth = pointingFrameSize.width / 2
        let gapBetweenFrameAndHead: CGFloat = 10
        let headCenterXRightOfFrame = targetInGlobalSpace.x + frameHalfWidth + PetPointingFrameView.depthEdgeOutset
            + gapBetweenFrameAndHead + headHalfSide
        let headCenterXLeftOfFrame = targetInGlobalSpace.x - frameHalfWidth - gapBetweenFrameAndHead - headHalfSide
        let edgeMargin: CGFloat = 8
        let fitsRightOfFrame = headCenterXRightOfFrame + headHalfSide <= targetDisplayFrame.maxX - edgeMargin
        let fitsLeftOfFrame = headCenterXLeftOfFrame - headHalfSide >= targetDisplayFrame.minX + edgeMargin
        let isCursorRightOfTarget = cursorLocation.x >= targetInGlobalSpace.x
        let landsRightOfFrame = (isCursorRightOfTarget && fitsRightOfFrame) || !fitsLeftOfFrame
        let frameTopY = targetInGlobalSpace.y + pointingFrameSize.height / 2
        let headDestination = CGPoint(
            x: landsRightOfFrame
                ? min(headCenterXRightOfFrame, targetDisplayFrame.maxX - edgeMargin - headHalfSide)
                : max(headCenterXLeftOfFrame, targetDisplayFrame.minX + edgeMargin + headHalfSide),
            y: min(
                max(frameTopY - 8 - headHalfSide, targetDisplayFrame.minY + edgeMargin + headHalfSide),
                targetDisplayFrame.maxY - edgeMargin - headHalfSide
            )
        )

        pointingTargetInGlobalSpace = targetInGlobalSpace
        isPointingRingShown = false
        hootQuietSinceDate = nil
        phase = .flyingToTarget

        let flightDistance = hypot(headDestination.x - petCenterInGlobalSpace.x, headDestination.y - petCenterInGlobalSpace.y)
        let flightDuration = min(max(flightDistance / 1100, 0.35), 0.8)
        startFlight(destination: .fixedPoint(headDestination), durationInSeconds: flightDuration) { [weak self] in
            guard let self, self.phase == .flyingToTarget else { return }
            self.phase = .pointingAtTarget
            self.pointingStartDate = Date()
            self.isPointingRingShown = true
            self.animatePointingFrameIn()
        }
    }

    /// In: the frame draws clockwise in 8 steps over 240ms while the fill
    /// fades in; the tab rises 4pt → 0 in 2 steps from 160ms. Reduce Motion
    /// skips the draw for a quick fade.
    private func animatePointingFrameIn() {
        pointingFrameAnimationTask?.cancel()
        pointingFrameOpacity = 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pointingFrameDrawProgress = 1
            pointingTabRiseOffset = 0
            pointingTabOpacity = 1
            return
        }
        pointingFrameDrawProgress = 0
        pointingTabRiseOffset = 4
        pointingTabOpacity = 0
        pointingFrameAnimationTask = Task { @MainActor [weak self] in
            for drawStep in 1...8 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pointingFrameDrawProgress = CGFloat(drawStep) / 8
                if drawStep == 6 {
                    self.pointingTabOpacity = 1
                    self.pointingTabRiseOffset = 2
                } else if drawStep == 8 {
                    self.pointingTabRiseOffset = 0
                }
            }
        }
    }

    /// Out: frame + tab fade to 0 in 3 steps over 150ms.
    private func animatePointingFrameOut() {
        pointingFrameAnimationTask?.cancel()
        pointingFrameAnimationTask = Task { @MainActor [weak self] in
            for fadeStep in 1...3 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pointingFrameOpacity = 1 - Double(fadeStep) / 3
            }
        }
    }

    /// Back to the parking spot the question was asked from (so the bubble
    /// returns to where the learner was reading), or to the live cursor when
    /// there is none, as after a new hold while pointing.
    private func flyBackToCursorAfterPointing() {
        isPointingRingShown = false
        animatePointingFrameOut()
        phase = .flyingBackToCursor
        let returnSpot = parkedHeadCenterInGlobalSpace ?? headCenterBesideCursor(cursorLocation: NSEvent.mouseLocation)
        let returnDestination: PetFlightDestination = parkedHeadCenterInGlobalSpace.map { .fixedPoint($0) } ?? .headSpotBesideCursor
        let flightDistance = hypot(returnSpot.x - petCenterInGlobalSpace.x, returnSpot.y - petCenterInGlobalSpace.y)
        let flightDuration = min(max(flightDistance / 1100, 0.3), 0.7)
        startFlight(destination: returnDestination, durationInSeconds: flightDuration) { [weak self] in
            guard let self, self.phase == .flyingBackToCursor else { return }
            self.pointingTargetInGlobalSpace = nil
            self.hootQuietSinceDate = nil
            self.phase = .atCursor
            self.hootController.clearDetectedElementLocation()
        }
    }

    // MARK: - Flights

    private enum PetFlightDestination {
        case fixedPoint(CGPoint)
        /// Re-read every frame, so hoot lands on a moving cursor.
        case headSpotBesideCursor
    }

    private struct PetFlight {
        let startPosition: CGPoint
        let destination: PetFlightDestination
        let startDate: Date
        let durationInSeconds: TimeInterval
        let onLanding: () -> Void
    }

    private func startFlight(
        destination: PetFlightDestination,
        durationInSeconds: TimeInterval,
        onLanding: @escaping () -> Void
    ) {
        activeFlight = PetFlight(
            startPosition: petCenterInGlobalSpace,
            destination: destination,
            startDate: Date(),
            durationInSeconds: max(durationInSeconds, 0.01),
            onLanding: onLanding
        )
        flightTrailPositionsInGlobalSpace = [petCenterInGlobalSpace]
        flightTrailOpacity = 1
    }

    /// Moves hoot along a gentle upward arc (a quadratic curve whose bend
    /// point sits above the straight line), with ease-in-out timing based on
    /// elapsed time so a slow frame never slows the flight down.
    private func advanceActiveFlight(now: Date, cursorLocation: CGPoint) {
        guard let flight = activeFlight else { return }

        let destinationPosition: CGPoint
        switch flight.destination {
        case .fixedPoint(let fixedPoint):
            destinationPosition = fixedPoint
        case .headSpotBesideCursor:
            destinationPosition = headCenterBesideCursor(cursorLocation: cursorLocation)
        }

        let linearProgress = min(now.timeIntervalSince(flight.startDate) / flight.durationInSeconds, 1)
        let easedProgress = CGFloat(Self.easeInOutCubic(linearProgress))
        let bendPoint = Self.arcBendPoint(from: flight.startPosition, to: destinationPosition)

        let remainingProgress = 1 - easedProgress
        let flightPosition = CGPoint(
            x: remainingProgress * remainingProgress * flight.startPosition.x
                + 2 * remainingProgress * easedProgress * bendPoint.x
                + easedProgress * easedProgress * destinationPosition.x,
            y: remainingProgress * remainingProgress * flight.startPosition.y
                + 2 * remainingProgress * easedProgress * bendPoint.y
                + easedProgress * easedProgress * destinationPosition.y
        )
        petCenterInGlobalSpace = flightPosition
        flightTrailPositionsInGlobalSpace.append(flightPosition)

        guard linearProgress >= 1 else { return }
        activeFlight = nil
        fadeOutFlightTrail()
        flight.onLanding()
    }

    private func fadeOutFlightTrail() {
        withAnimation(.easeOut(duration: 0.6)) {
            flightTrailOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            // A new flight may have started meanwhile; keep its trail.
            guard let self, self.activeFlight == nil else { return }
            self.flightTrailPositionsInGlobalSpace = []
        }
    }

    private static func easeInOutCubic(_ linearProgress: Double) -> Double {
        if linearProgress < 0.5 {
            return 4 * linearProgress * linearProgress * linearProgress
        }
        let mirroredProgress = -2 * linearProgress + 2
        return 1 - mirroredProgress * mirroredProgress * mirroredProgress / 2
    }

    /// The bend point of the arc: the midpoint pushed sideways from the
    /// straight line by a fifth of the distance (at most 90pt), on whichever
    /// side is "up" on screen so hoot hops over rather than dips under.
    private static func arcBendPoint(from startPosition: CGPoint, to endPosition: CGPoint) -> CGPoint {
        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)
        let midpoint = CGPoint(x: (startPosition.x + endPosition.x) / 2, y: (startPosition.y + endPosition.y) / 2)
        guard distance > 1 else { return midpoint }

        // Unit perpendicular, flipped to point up (global +y).
        var perpendicularX = -deltaY / distance
        var perpendicularY = deltaX / distance
        if perpendicularY < 0 || (perpendicularY == 0 && perpendicularX < 0) {
            perpendicularX = -perpendicularX
            perpendicularY = -perpendicularY
        }
        let arcHeight = min(distance * 0.2, 90)
        return CGPoint(x: midpoint.x + perpendicularX * arcHeight, y: midpoint.y + perpendicularY * arcHeight)
    }
}
