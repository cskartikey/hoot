//
//  PetWalkthroughCoordinator.swift
//  Hoot
//
//  The stepped driver for walkthrough mode (docs/design/WALKTHROUGH.md).
//  One index-card frame for the whole walkthrough: it draws in at step 1,
//  slides (and resizes) to each next step on the sentence boundary, then
//  waits, peeks, checks, and either turns `accent2` with a pixel check or
//  slides back to the step the learner missed.
//
//  Everything is stepped: a one-shot Timer re-armed per keyframe holds each
//  discrete state for its duration. No `withAnimation`, no easing, no tween
//  between steps; the "ease-out" of the slide is the front-loaded fractions.
//
//  `PetOverlayCoordinator` hands over when the controller publishes a
//  walkthrough (phase `.walkthrough`): it feeds this object every frame tick
//  and copies the head position back out; `hasFinished` hands control back.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PetWalkthroughCoordinator: ObservableObject {
    // MARK: Published frame state (read by PetWalkthroughFrameLayer)

    @Published private(set) var isActive = false
    /// The padded frame, AppKit global coordinates (bottom-left origin).
    @Published private(set) var frameRectInGlobalSpace: CGRect?
    @Published private(set) var frameOpacity: Double = 0
    @Published private(set) var drawProgress: CGFloat = 0
    @Published private(set) var fillLevel: CGFloat = 1
    @Published private(set) var depthLevel: CGFloat = 1
    @Published private(set) var isFillFlashing = false
    @Published private(set) var tone: PetPointingFrameTone = .accent
    @Published private(set) var tabContent = PetPointingTabContent()
    @Published private(set) var tabRiseOffset: CGFloat = 0
    @Published private(set) var tabOpacity: Double = 1
    @Published private(set) var isTabBelowFrame = false
    @Published private(set) var isTabMirroredLeft = false

    // MARK: Head state (read by PetOverlayCoordinator each tick)

    private(set) var headCenterInGlobalSpace: CGPoint?
    /// The frame is to the head's left, so the head is mirrored to face it.
    private(set) var isHeadFacingLeft = false
    /// Set once the out animation has ended; the overlay coordinator takes over.
    private(set) var hasFinished = false

    /// Installed by PetOverlayCoordinator: the existing bezier flight with
    /// the dotted trail, used for the first approach and the far fallback.
    var flyHead: ((_ destination: CGPoint, _ onLanding: @escaping () -> Void) -> Void)?

    // MARK: Tuning (spec numbers)

    /// Slide + resize: 10 states over 320ms.
    private static let liftStepMilliseconds = 30
    private static let travelFractions: [CGFloat] = [0.30, 0.55, 0.75, 0.88, 0.96, 1.0]
    private static let travelStepMilliseconds = 30
    private static let landStepMilliseconds = 40
    /// Beyond this (or another display) the frame fades out and hoot flies.
    private static let maximumSlideDistanceInPoints: CGFloat = 480
    private static let headGapFromFrame: CGFloat = 10
    private static let headBackOffWhileWaiting: CGFloat = 6
    private static let waitingDotsStepMilliseconds = 400
    private static let checkingDotsStepMilliseconds = 200
    private static let cursorWatchIntervalInSeconds: TimeInterval = 0.24

    private enum HeadSide {
        case left
        case right
    }

    // MARK: Private state

    private var steps: [HootWalkthroughStep] = []
    private var totalStepCount = 1
    private var currentStepIndex = 0
    /// Chosen once at step 1 and locked, so the head never ping-pongs.
    private var lockedHeadSide: HeadSide = .right
    private var headBackOffDistance: CGFloat = 0
    private var headAnimationStateOverride: PetAnimationState?
    private var lastHandledPhase: HootWalkthroughPhase?
    private var isAwaitingFlightLanding = false
    private var isGoingOut = false
    private var isDoneScriptRunning = false
    private var lastCursorWatchDate = Date.distantPast
    private var lastCursorLocation = CGPoint.zero

    private struct Keyframe {
        let holdMilliseconds: Int
        let apply: () -> Void
    }
    private var keyframeQueue: [Keyframe] = []
    private var keyframeCompletion: (() -> Void)?
    private var keyframeTimer: Timer?

    // MARK: - Head state for the overlay

    func headAnimationState(isAudioPlaying: Bool) -> PetAnimationState {
        if let headAnimationStateOverride { return headAnimationStateOverride }
        // Talking through the move (mid-sentence); idle in the gaps.
        return isAudioPlaying ? .talking : .idle
    }

    // MARK: - Driving from the overlay coordinator

    /// Called every frame tick while the overlay is in `.walkthrough`.
    func update(state: HootWalkthroughState?, cursorLocation: CGPoint, isAudioPlaying: Bool) {
        lastCursorLocation = cursorLocation
        guard let state, !state.steps.isEmpty else {
            // The controller forgot the walkthrough (new question / stop).
            if isActive { goOutAndFinish() }
            return
        }
        steps = state.steps
        totalStepCount = max(state.totalStepCount, steps.count)
        if isAwaitingFlightLanding { return }

        if state.phase == .waiting { watchCursorIfDue() }
        guard state.phase != lastHandledPhase else { return }
        lastHandledPhase = state.phase

        switch state.phase {
        case .gathering:
            break
        case .step(let stepIndex):
            if !isActive {
                begin(atStepIndex: stepIndex, cursorLocation: cursorLocation)
            } else if stepIndex != currentStepIndex {
                move(toStepIndex: stepIndex, transitBadge: badgeText(forStepIndex: stepIndex), landBadge: badgeText(forStepIndex: stepIndex))
            }
        case .waiting:
            startWaiting()
        case .peek:
            startPeek()
        case .checking:
            startChecking()
        case .done:
            startDone()
        case .missed(let stepIndex):
            headAnimationStateOverride = nil
            headBackOffDistance = 0
            if stepIndex != currentStepIndex || !isActive {
                move(toStepIndex: stepIndex, transitBadge: "still this one", landBadge: "still this one")
            } else {
                // Missed the step the frame is already on: back to the landed look.
                cancelScript()
                fillLevel = 1
                depthLevel = 1
                isFillFlashing = false
                setTab(PetPointingTabContent(badge: "still this one", label: steps[stepIndex].label))
                placeHead(forFrameRect: frameRectInGlobalSpace ?? .zero, snapToPixelGrid: false)
            }
        case .ended:
            // The done script holds its own 1000ms and goes out by itself.
            if !isDoneScriptRunning { goOutAndFinish() }
        }
    }

    /// A new question cut in: drop everything at once (the head is already
    /// flying back to the cursor).
    func abort() {
        cancelScript()
        isActive = false
        hasFinished = false
        isGoingOut = false
        isDoneScriptRunning = false
        isAwaitingFlightLanding = false
        frameOpacity = 0
        frameRectInGlobalSpace = nil
        headCenterInGlobalSpace = nil
        headAnimationStateOverride = nil
        headBackOffDistance = 0
        lastHandledPhase = nil
        isHeadFacingLeft = false
    }

    /// The overlay coordinator took control back after `hasFinished`.
    func reset() {
        abort()
    }

    // MARK: - Starting

    private func begin(atStepIndex stepIndex: Int, cursorLocation: CGPoint) {
        guard steps.indices.contains(stepIndex) else { return }
        cancelScript()
        isActive = true
        hasFinished = false
        isGoingOut = false
        currentStepIndex = stepIndex
        tone = .accent
        fillLevel = 1
        depthLevel = 1
        isFillFlashing = false
        frameOpacity = 0
        drawProgress = 0
        tabOpacity = 0
        tabRiseOffset = 4
        headBackOffDistance = 0
        headAnimationStateOverride = nil

        let stepRect = frameRect(forStepIndex: stepIndex)
        frameRectInGlobalSpace = stepRect
        let fullTab = fullTabContent(forStepIndex: stepIndex)
        setTab(fullTab)
        updateTabPlacement(forFrameRect: stepRect, stepIndex: stepIndex)

        // Side chosen once, on the cursor's side, falling back if it doesn't fit.
        let displayFrame = steps[stepIndex].displayFrame
        let preferredSide: HeadSide = cursorLocation.x >= stepRect.midX ? .right : .left
        lockedHeadSide = headSide(thatFits: preferredSide, forFrameRect: stepRect, displayFrame: displayFrame)
        let destination = headCenter(forFrameRect: stepRect, side: lockedHeadSide, displayFrame: displayFrame)
        isHeadFacingLeft = lockedHeadSide == .right

        isAwaitingFlightLanding = true
        let landed = { [weak self] in
            guard let self else { return }
            self.isAwaitingFlightLanding = false
            self.headCenterInGlobalSpace = destination
            self.drawIn(announcingStepIndex: stepIndex)
        }
        if let flyHead {
            flyHead(destination, landed)
        } else {
            landed()
        }
    }

    /// In: 8 steps over 240ms clockwise, fill with it; tab rises 4 → 0 in
    /// 2 steps from 160ms. Reduce Motion: appears at full in 120ms.
    private func drawIn(announcingStepIndex stepIndex: Int) {
        frameOpacity = 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            runScript([
                Keyframe(holdMilliseconds: 120) { [weak self] in
                    self?.drawProgress = 0; self?.tabOpacity = 0
                },
                Keyframe(holdMilliseconds: 0) { [weak self] in
                    self?.drawProgress = 1; self?.tabOpacity = 1; self?.tabRiseOffset = 0
                    self?.fillLevel = 1; self?.depthLevel = 1
                },
            ]) { [weak self] in self?.announceLanding(atStepIndex: stepIndex) }
            return
        }
        var keyframes: [Keyframe] = []
        for drawStep in 1...8 {
            keyframes.append(Keyframe(holdMilliseconds: 30) { [weak self] in
                guard let self else { return }
                self.drawProgress = CGFloat(drawStep) / 8
                self.fillLevel = CGFloat(drawStep) / 8
                self.depthLevel = CGFloat(drawStep) / 8
                if drawStep == 6 {
                    self.tabOpacity = 1
                    self.tabRiseOffset = 2
                } else if drawStep == 8 {
                    self.tabRiseOffset = 0
                }
            })
        }
        runScript(keyframes) { [weak self] in self?.announceLanding(atStepIndex: stepIndex) }
    }

    // MARK: - Step-to-step move

    private func move(toStepIndex stepIndex: Int, transitBadge: String, landBadge: String) {
        guard steps.indices.contains(stepIndex), let oldRect = frameRectInGlobalSpace else {
            begin(atStepIndex: stepIndex, cursorLocation: lastCursorLocation)
            return
        }
        cancelScript()
        isFillFlashing = false
        headAnimationStateOverride = nil
        headBackOffDistance = 0
        currentStepIndex = stepIndex
        let newStep = steps[stepIndex]
        let newRect = frameRect(forStepIndex: stepIndex)
        let oldDisplayFrame = PetOverlayCoordinateSpace.screenFrame(containingGlobalPoint: CGPoint(x: oldRect.midX, y: oldRect.midY))
        let isOnAnotherDisplay = oldDisplayFrame != nil && oldDisplayFrame != newStep.displayFrame
        let centerDistance = hypot(newRect.midX - oldRect.midX, newRect.midY - oldRect.midY)
        let landTab = PetPointingTabContent(badge: landBadge, label: newStep.label)

        // Re-flip only if the locked side doesn't fit the new box.
        let sideForNewBox = headSide(thatFits: lockedHeadSide, forFrameRect: newRect, displayFrame: newStep.displayFrame)
        lockedHeadSide = sideForNewBox
        let newHeadCenter = headCenter(forFrameRect: newRect, side: sideForNewBox, displayFrame: newStep.displayFrame)

        if isOnAnotherDisplay || centerDistance > Self.maximumSlideDistanceInPoints {
            fadeOutFlyAndRedraw(toStepIndex: stepIndex, newRect: newRect, newHeadCenter: newHeadCenter, landTab: landTab)
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No travel: old frame out in 60ms, new frame in at full in 120ms, head jumps.
            runScript([
                Keyframe(holdMilliseconds: 60) { [weak self] in self?.frameOpacity = 0 },
                Keyframe(holdMilliseconds: 120) { [weak self] in
                    guard let self else { return }
                    self.frameRectInGlobalSpace = newRect
                    self.headCenterInGlobalSpace = newHeadCenter
                    self.isHeadFacingLeft = sideForNewBox == .right
                    self.setTab(landTab)
                    self.updateTabPlacement(forFrameRect: newRect, stepIndex: stepIndex)
                },
                Keyframe(holdMilliseconds: 0) { [weak self] in self?.frameOpacity = 1 },
            ]) { [weak self] in self?.announceLanding(atStepIndex: stepIndex) }
            return
        }

        let oldHeadCenter = headCenterInGlobalSpace ?? newHeadCenter
        var keyframes: [Keyframe] = []
        // lift 1: 50% fill, badge only.
        keyframes.append(Keyframe(holdMilliseconds: Self.liftStepMilliseconds) { [weak self] in
            guard let self else { return }
            self.fillLevel = 0.5
            self.depthLevel = 0.5
            self.drawProgress = 1
            self.setTab(PetPointingTabContent(badge: transitBadge, label: nil))
        })
        // lift 2: outline only.
        keyframes.append(Keyframe(holdMilliseconds: Self.liftStepMilliseconds) { [weak self] in
            self?.fillLevel = 0
            self?.depthLevel = 0
        })
        // travel 1–6: lerp x, y, w, h independently, snapped to 2pt; head in lockstep.
        for fraction in Self.travelFractions {
            keyframes.append(Keyframe(holdMilliseconds: Self.travelStepMilliseconds) { [weak self] in
                guard let self else { return }
                self.frameRectInGlobalSpace = Self.lerpRectSnappedToPixelGrid(from: oldRect, to: newRect, fraction: fraction)
                self.headCenterInGlobalSpace = Self.lerpPointSnappedToPixelGrid(from: oldHeadCenter, to: newHeadCenter, fraction: fraction)
            })
        }
        // land 1: new box, 50%, badge + first half of the label; tab side for the new box; head flip.
        keyframes.append(Keyframe(holdMilliseconds: Self.landStepMilliseconds) { [weak self] in
            guard let self else { return }
            self.frameRectInGlobalSpace = newRect
            self.headCenterInGlobalSpace = newHeadCenter
            self.isHeadFacingLeft = sideForNewBox == .right
            self.fillLevel = 0.5
            self.depthLevel = 0.5
            let halfLabel = newStep.label.map { String($0.prefix(($0.count + 1) / 2)) }
            self.setTab(PetPointingTabContent(badge: landBadge, label: halfLabel))
            self.updateTabPlacement(forFrameRect: newRect, stepIndex: stepIndex)
        })
        // land 2: 100%, full tab.
        keyframes.append(Keyframe(holdMilliseconds: Self.landStepMilliseconds) { [weak self] in
            guard let self else { return }
            self.fillLevel = 1
            self.depthLevel = 1
            self.setTab(landTab)
        })
        runScript(keyframes) { [weak self] in self?.announceLanding(atStepIndex: stepIndex) }
    }

    /// Fallback for far / cross-display moves: existing out (3 steps over
    /// 150ms), hoot's existing flight with the trail, existing draw-in.
    private func fadeOutFlyAndRedraw(toStepIndex stepIndex: Int, newRect: CGRect, newHeadCenter: CGPoint, landTab: PetPointingTabContent) {
        runOutScript { [weak self] in
            guard let self else { return }
            self.frameRectInGlobalSpace = newRect
            self.setTab(landTab)
            self.updateTabPlacement(forFrameRect: newRect, stepIndex: stepIndex)
            self.drawProgress = 0
            self.tabOpacity = 0
            self.tabRiseOffset = 4
            self.isAwaitingFlightLanding = true
            let landed = { [weak self] in
                guard let self else { return }
                self.isAwaitingFlightLanding = false
                self.headCenterInGlobalSpace = newHeadCenter
                self.isHeadFacingLeft = self.lockedHeadSide == .right
                self.drawIn(announcingStepIndex: stepIndex)
            }
            if let flyHead = self.flyHead {
                flyHead(newHeadCenter, landed)
            } else {
                landed()
            }
        }
    }

    // MARK: - Waiting, peek, checking

    /// Fill → 0 in 2 steps over 80ms, then "your turn" + dots stepping
    /// every 400ms; the head backs off 6pt in 2 steps over 60ms.
    private func startWaiting() {
        cancelScript()
        isFillFlashing = false
        tone = .accent
        // t0 fill 50% + head +3, t30 head +6, t40 fill 0, t80 "your turn".
        runScript([
            Keyframe(holdMilliseconds: 30) { [weak self] in
                self?.fillLevel = 0.5
                self?.setHeadBackOff(3)
            },
            Keyframe(holdMilliseconds: 10) { [weak self] in
                self?.setHeadBackOff(6)
            },
            Keyframe(holdMilliseconds: 40) { [weak self] in
                self?.fillLevel = 0
            },
        ]) { [weak self] in
            guard let self else { return }
            self.setTab(PetPointingTabContent(badge: "your turn", label: nil, litDotCount: 0))
            self.runDotsLoop(badge: "your turn", stepMilliseconds: Self.waitingDotsStepMilliseconds)
        }
        lastCursorWatchDate = .distantPast
        watchCursorIfDue()
    }

    /// `watching`, or `watchingIn` while the cursor is inside the framed box,
    /// re-evaluated on a 240ms tick (stepped, not continuous).
    private func watchCursorIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastCursorWatchDate) >= Self.cursorWatchIntervalInSeconds else { return }
        lastCursorWatchDate = now
        let isCursorInsideBox = frameRectInGlobalSpace?.contains(lastCursorLocation) ?? false
        let watchingState: PetAnimationState = isCursorInsideBox ? .watchingIn : .watching
        if headAnimationStateOverride != watchingState {
            headAnimationStateOverride = watchingState
        }
    }

    /// 240ms: head `peek`; the fill flashes once for 60ms, then back to 0.
    private func startPeek() {
        cancelScript()
        headAnimationStateOverride = .peek
        runScript([
            Keyframe(holdMilliseconds: 60) { [weak self] in self?.isFillFlashing = true },
            Keyframe(holdMilliseconds: 180) { [weak self] in
                self?.isFillFlashing = false
                self?.fillLevel = 0
            },
        ])
    }

    private func startChecking() {
        cancelScript()
        isFillFlashing = false
        headAnimationStateOverride = .thinking
        setTab(PetPointingTabContent(badge: "checking", label: nil, litDotCount: 0))
        runDotsLoop(badge: "checking", stepMilliseconds: Self.checkingDotsStepMilliseconds)
    }

    /// 4-step loop: 0, 1, 2, 3 dots lit.
    private func runDotsLoop(badge: String, stepMilliseconds: Int) {
        let keyframes = (0...3).map { litDotCount in
            Keyframe(holdMilliseconds: stepMilliseconds) { [weak self] in
                self?.setTab(PetPointingTabContent(badge: badge, label: nil, litDotCount: litDotCount))
            }
        }
        runScript(keyframes) { [weak self] in
            self?.runDotsLoop(badge: badge, stepMilliseconds: stepMilliseconds)
        }
    }

    // MARK: - Done

    /// Hard cut to `accent2` (fill back to normal in the same step), check in
    /// 3 × 40ms (cells 1–2, 1–4, 1–7), head `happy`, hold to 1000ms, out.
    private func startDone() {
        cancelScript()
        isFillFlashing = false
        headAnimationStateOverride = .happy
        isDoneScriptRunning = true
        runScript([
            Keyframe(holdMilliseconds: 40) { [weak self] in
                guard let self else { return }
                self.tone = .accent2
                self.fillLevel = 1
                self.depthLevel = 1
                self.setTab(PetPointingTabContent(badge: "done", label: nil, drawnCheckCellCount: 2))
            },
            Keyframe(holdMilliseconds: 40) { [weak self] in
                self?.setTab(PetPointingTabContent(badge: "done", label: nil, drawnCheckCellCount: 4))
            },
            Keyframe(holdMilliseconds: 1000 - 80) { [weak self] in
                self?.setTab(PetPointingTabContent(badge: "done", label: nil, drawnCheckCellCount: 7))
            },
        ]) { [weak self] in
            self?.isDoneScriptRunning = false
            self?.announce("done")
            self?.goOutAndFinish()
        }
    }

    // MARK: - Out

    /// Whole frame + tab opacity → 0 in 3 steps over 150ms, then hand back.
    private func goOutAndFinish() {
        guard isActive, !isGoingOut else { return }
        isGoingOut = true
        isAwaitingFlightLanding = false
        headAnimationStateOverride = nil
        runOutScript { [weak self] in
            guard let self else { return }
            self.isActive = false
            self.hasFinished = true
        }
    }

    private func runOutScript(completion: @escaping () -> Void) {
        cancelScript()
        runScript([
            Keyframe(holdMilliseconds: 50) { [weak self] in self?.frameOpacity = 2.0 / 3.0 },
            Keyframe(holdMilliseconds: 50) { [weak self] in self?.frameOpacity = 1.0 / 3.0 },
            Keyframe(holdMilliseconds: 50) { [weak self] in self?.frameOpacity = 0 },
        ], completion: completion)
    }

    // MARK: - Geometry

    private func frameRect(forStepIndex stepIndex: Int) -> CGRect {
        let step = steps[stepIndex]
        let frameSize = PetPointingFrameView.paddedFrameSize(forElementSize: step.globalBoxSize, screenSize: step.displayFrame.size)
        // Snap the origin to whole points so the 2pt pixels stay crisp.
        return CGRect(
            x: (step.globalCenter.x - frameSize.width / 2).rounded(),
            y: (step.globalCenter.y - frameSize.height / 2).rounded(),
            width: frameSize.width,
            height: frameSize.height
        )
    }

    /// Head center beside the frame: top 8pt below the frame top, 10pt
    /// outside (past the depth edge on the right), clamped to the display.
    private func headCenter(forFrameRect frameRect: CGRect, side: HeadSide, displayFrame: CGRect) -> CGPoint {
        let headHalfSide = PetOverlayCoordinator.headSideLength / 2
        let edgeMargin: CGFloat = 8
        let gap = Self.headGapFromFrame + headBackOffDistance
        let centerX: CGFloat
        switch side {
        case .right:
            centerX = min(frameRect.maxX + PetPointingFrameView.depthEdgeOutset + gap + headHalfSide, displayFrame.maxX - edgeMargin - headHalfSide)
        case .left:
            centerX = max(frameRect.minX - gap - headHalfSide, displayFrame.minX + edgeMargin + headHalfSide)
        }
        let centerY = min(
            max(frameRect.maxY - 8 - headHalfSide, displayFrame.minY + edgeMargin + headHalfSide),
            displayFrame.maxY - edgeMargin - headHalfSide
        )
        return CGPoint(x: centerX, y: centerY)
    }

    private func headSide(thatFits preferredSide: HeadSide, forFrameRect frameRect: CGRect, displayFrame: CGRect) -> HeadSide {
        let headSideLength = PetOverlayCoordinator.headSideLength
        let edgeMargin: CGFloat = 8
        let fitsRight = frameRect.maxX + PetPointingFrameView.depthEdgeOutset + Self.headGapFromFrame + headSideLength <= displayFrame.maxX - edgeMargin
        let fitsLeft = frameRect.minX - Self.headGapFromFrame - headSideLength >= displayFrame.minX + edgeMargin
        switch preferredSide {
        case .right: return fitsRight || !fitsLeft ? .right : .left
        case .left: return fitsLeft || !fitsRight ? .left : .right
        }
    }

    private func placeHead(forFrameRect frameRect: CGRect, snapToPixelGrid: Bool) {
        guard steps.indices.contains(currentStepIndex) else { return }
        headCenterInGlobalSpace = headCenter(forFrameRect: frameRect, side: lockedHeadSide, displayFrame: steps[currentStepIndex].displayFrame)
    }

    private func setHeadBackOff(_ distance: CGFloat) {
        headBackOffDistance = distance
        if let frameRectInGlobalSpace {
            placeHead(forFrameRect: frameRectInGlobalSpace, snapToPixelGrid: false)
        }
    }

    /// Flip below near the top of the screen; mirror left when the tab would
    /// run off the right edge. Evaluated for the box being landed on.
    private func updateTabPlacement(forFrameRect frameRect: CGRect, stepIndex: Int) {
        let displayFrame = steps[stepIndex].displayFrame
        isTabBelowFrame = frameRect.maxY + PetPointingFrameView.tabVisibleHeightAboveFrame > displayFrame.maxY - 8
        let widestTabForThisStep = fullTabContent(forStepIndex: stepIndex)
            .estimatedWidth(maximumWidth: PetPointingFrameView.walkthroughTabMaximumWidth(forFrameWidth: frameRect.width))
        isTabMirroredLeft = frameRect.minX + PetPointingFrameView.tabInsetFromFrameLeft + widestTabForThisStep > displayFrame.maxX - 8
    }

    private static func snappedToPixelGrid(_ value: CGFloat) -> CGFloat {
        (value / 2).rounded() * 2
    }

    private static func lerpRectSnappedToPixelGrid(from oldRect: CGRect, to newRect: CGRect, fraction: CGFloat) -> CGRect {
        CGRect(
            x: snappedToPixelGrid(oldRect.minX + (newRect.minX - oldRect.minX) * fraction),
            y: snappedToPixelGrid(oldRect.minY + (newRect.minY - oldRect.minY) * fraction),
            width: snappedToPixelGrid(oldRect.width + (newRect.width - oldRect.width) * fraction),
            height: snappedToPixelGrid(oldRect.height + (newRect.height - oldRect.height) * fraction)
        )
    }

    private static func lerpPointSnappedToPixelGrid(from oldPoint: CGPoint, to newPoint: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(
            x: snappedToPixelGrid(oldPoint.x + (newPoint.x - oldPoint.x) * fraction),
            y: snappedToPixelGrid(oldPoint.y + (newPoint.y - oldPoint.y) * fraction)
        )
    }

    // MARK: - Tab text

    private func badgeText(forStepIndex stepIndex: Int) -> String {
        "\(stepIndex + 1) of \(totalStepCount)"
    }

    private func fullTabContent(forStepIndex stepIndex: Int) -> PetPointingTabContent {
        PetPointingTabContent(badge: badgeText(forStepIndex: stepIndex), label: steps[stepIndex].label)
    }

    private func setTab(_ content: PetPointingTabContent) {
        if content != tabContent { tabContent = content }
    }

    // MARK: - Accessibility

    private func announceLanding(atStepIndex stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        let label = steps[stepIndex].label.map { ", \($0)" } ?? ""
        announce("step \(stepIndex + 1) of \(totalStepCount)\(label)")
    }

    private func announce(_ announcement: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    // MARK: - Keyframe script (the one timer)

    /// Applies each keyframe in turn, holding it for its duration on a
    /// one-shot timer re-armed per step; `completion` runs after the last hold.
    private func runScript(_ keyframes: [Keyframe], completion: (() -> Void)? = nil) {
        cancelScript()
        keyframeQueue = keyframes
        keyframeCompletion = completion
        advanceScript()
    }

    private func advanceScript() {
        guard !keyframeQueue.isEmpty else {
            let completion = keyframeCompletion
            keyframeCompletion = nil
            completion?()
            return
        }
        let keyframe = keyframeQueue.removeFirst()
        keyframe.apply()
        let holdSeconds = Double(max(keyframe.holdMilliseconds, 0)) / 1000
        let timer = Timer(timeInterval: holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceScript()
            }
        }
        // .common so the walkthrough keeps stepping while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        keyframeTimer = timer
    }

    private func cancelScript() {
        keyframeTimer?.invalidate()
        keyframeTimer = nil
        keyframeQueue = []
        keyframeCompletion = nil
    }
}
