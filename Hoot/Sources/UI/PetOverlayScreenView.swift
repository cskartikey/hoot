//
//  PetOverlayScreenView.swift
//  Hoot
//
//  What one display's overlay window draws. The coordinator keeps hoot's
//  state in global coordinates; this view converts to its own screen and
//  draws whatever lands on it: the trail, the pointing ring, hoot itself,
//  and (only on the screen hoot is currently on) the pieces around the head.
//

import AppKit
import SwiftUI

struct PetOverlayScreenView: View {
    /// This display's frame in AppKit global coordinates.
    let screenFrame: CGRect
    @ObservedObject var petOverlayCoordinator: PetOverlayCoordinator
    @ObservedObject var hootController: HootController
    @ObservedObject private var themeStore = WaitWhatThemeStore.shared

    // Measured so the pieces can be placed (and clamped) beside the head.
    @State private var transcriptBubbleSize: CGSize = .zero
    @State private var answerBubbleSize: CGSize = .zero
    @State private var followUpPillSize: CGSize = .zero
    @State private var pointingLabelChipSize: CGSize = .zero

    var body: some View {
        let theme = themeStore.theme
        let petCenterInGlobalSpace = petOverlayCoordinator.petCenterInGlobalSpace
        let petCenter = localPoint(fromGlobalPoint: petCenterInGlobalSpace)
        let petSideLength = petOverlayCoordinator.isPetDrawnAsFullBody
            ? PetOverlayCoordinator.fullBodySideLength
            : PetOverlayCoordinator.headSideLength
        // A little slack so hoot crossing onto the next display is drawn on both.
        let isPetNearThisScreen = screenFrame.insetBy(dx: -petSideLength, dy: -petSideLength).contains(petCenterInGlobalSpace)
        let isPetOnThisScreen = PetOverlayCoordinateSpace.screenFrame(containingGlobalPoint: petCenterInGlobalSpace) == screenFrame
        let isPetVisible = petOverlayCoordinator.isPetVisible
        // While flying, the frame tick moves hoot every frame; an extra
        // animation on top would make it lag behind its own trail.
        let followAnimation: Animation? = petOverlayCoordinator.isPetFlying
            ? nil
            : .spring(response: 0.18, dampingFraction: 0.7)

        ZStack(alignment: .topLeading) {
            Color.clear

            PetFlightTrailView(
                flownPathPositions: petOverlayCoordinator.flightTrailPositionsInGlobalSpace.map(localPoint(fromGlobalPoint:)),
                dotColor: theme.accent
            )
            .opacity(petOverlayCoordinator.flightTrailOpacity)

            pointingRing(theme: theme)

            if isPetNearThisScreen {
                // The fade animation sits above `.position` so showing or
                // hiding the corner hoot never animates where it is.
                petSprite(isMirrored: petOverlayCoordinator.isHeadMirroredTowardTarget)
                    .scaleEffect(petOverlayCoordinator.petGrowScale)
                    .opacity(isPetVisible ? petOverlayCoordinator.petSessionOpacity : 0)
                    .animation(.easeInOut(duration: 0.35), value: isPetVisible)
                    .position(petCenter)
                    .animation(followAnimation, value: petCenter)
            }

            if isPetOnThisScreen && isPetVisible && !petOverlayCoordinator.isPetDrawnAsFullBody {
                piecesAroundHead(
                    headFrame: CGRect(
                        x: petCenter.x - PetOverlayCoordinator.headSideLength / 2,
                        y: petCenter.y - PetOverlayCoordinator.headSideLength / 2,
                        width: PetOverlayCoordinator.headSideLength,
                        height: PetOverlayCoordinator.headSideLength
                    ),
                    theme: theme,
                    followAnimation: followAnimation
                )
                .opacity(petOverlayCoordinator.petSessionOpacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: - Hoot

    @ViewBuilder
    private func petSprite(isMirrored: Bool) -> some View {
        if petOverlayCoordinator.isPetDrawnAsFullBody {
            PetSpriteView(state: petOverlayCoordinator.fullBodyAnimationState, scale: 2)
        } else {
            PetSpriteView(
                variant: .cursorHead,
                state: petOverlayCoordinator.headAnimationState,
                scale: 2,
                isMirrored: isMirrored
            )
        }
    }

    /// The index-card frame (POINTING.md) around what hoot points at, sized
    /// to the tutor's box, with the label in a tab on top.
    @ViewBuilder
    private func pointingRing(theme: WaitWhatTheme) -> some View {
        let frameSize = PetPointingFrameView.paddedFrameSize(
            forElementSize: hootController.detectedElementBoxSize,
            screenSize: screenFrame.size
        )
        if let pointingTargetInGlobalSpace = petOverlayCoordinator.pointingTargetInGlobalSpace,
           screenFrame.insetBy(dx: -(frameSize.width + 24), dy: -(frameSize.height + 24))
            .contains(pointingTargetInGlobalSpace) {
            let targetCenter = localPoint(fromGlobalPoint: pointingTargetInGlobalSpace)
            // Snap the top-left to whole points so the 2pt pixels stay crisp.
            let frameOrigin = CGPoint(
                x: (targetCenter.x - frameSize.width / 2).rounded(),
                y: (targetCenter.y - frameSize.height / 2).rounded()
            )
            let trimmedLabel = (hootController.detectedElementLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let usableLabel: String? = (trimmedLabel.isEmpty || trimmedLabel.lowercased() == "none") ? nil : trimmedLabel
            let isTabBelowFrame = frameOrigin.y - PetPointingFrameView.tabVisibleHeightAboveFrame < 8

            PetPointingFrameView(
                frameSize: frameSize,
                label: usableLabel,
                drawProgress: petOverlayCoordinator.pointingFrameDrawProgress,
                tabRiseOffset: petOverlayCoordinator.pointingTabRiseOffset,
                tabOpacity: petOverlayCoordinator.pointingTabOpacity,
                isTabBelowFrame: isTabBelowFrame,
                theme: theme
            )
            .opacity(petOverlayCoordinator.pointingFrameOpacity)
            // The view carries transparent room for the tab above the frame.
            .offset(x: frameOrigin.x, y: frameOrigin.y - PetPointingFrameView.roomForTabAboveAndBelow)
        }
    }

    // MARK: - Pieces around the head

    @ViewBuilder
    private func piecesAroundHead(headFrame: CGRect, theme: WaitWhatTheme, followAnimation: Animation?) -> some View {
        let screenSize = screenFrame.size
        let phase = petOverlayCoordinator.phase
        let voiceState = hootController.voiceState
        let isHeadRidingTheCursor = phase == .flyingToCursor || phase == .atCursor
        let isListening = isHeadRidingTheCursor && voiceState == .listening
        let liveTranscriptText = hootController.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let answerText = PetOverlayAnswerText.displayableText(fromStreamedResponseText: hootController.streamingResponseText)
        let isTalking = voiceState == .responding || petOverlayCoordinator.isResponseAudioPlaying
        let isAnswering = phase == .atCursor
            || phase == .flyingToTarget
            || phase == .pointingAtTarget
            || phase == .flyingBackToCursor
        let isShowingAnswerBubble = isAnswering && voiceState != .listening && isTalking && !answerText.isEmpty
        let isThinking = phase == .atCursor
            && voiceState == .processing
            && hootController.isAnswerPipelineRunning
            && !isTalking

        ZStack(alignment: .topLeading) {
            // Listening: 5 bars beside the head…
            if isListening {
                PetListeningBarsView(audioPowerLevel: hootController.audioPowerLevel, barColor: theme.accent2)
                    .position(
                        PetOverlayPlacement.centerForPieceBesideHead(
                            headFrame: headFrame,
                            pieceSize: PetListeningBarsView.barsSize,
                            screenSize: screenSize,
                            horizontalGapFromHead: 4,
                            topOffsetFromHeadTop: 6
                        )
                    )
                    .animation(followAnimation, value: headFrame)
                    .transition(.opacity)
            }

            // …and the live transcript under it.
            PetListeningTranscriptBubbleView(liveTranscriptText: liveTranscriptText, theme: theme)
                .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { newSize in
                    transcriptBubbleSize = newSize
                }
                .opacity(isListening && !liveTranscriptText.isEmpty ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isListening)
                .position(
                    PetOverlayPlacement.centerForBubbleBelowHead(
                        headFrame: headFrame,
                        bubbleSize: transcriptBubbleSize,
                        screenSize: screenSize
                    )
                )
                .animation(followAnimation, value: headFrame)

            // Thinking: three dots lighting up in turn.
            if isThinking {
                PetThinkingDotsView(dotColor: theme.accent)
                    .position(
                        PetOverlayPlacement.centerForPieceBesideHead(
                            headFrame: headFrame,
                            pieceSize: PetThinkingDotsView.dotsSize,
                            screenSize: screenSize,
                            horizontalGapFromHead: 6
                        )
                    )
                    .animation(followAnimation, value: headFrame)
                    .transition(.opacity)
            }

            // Talking: the answer under the head, kept off the pointing
            // frame so it never covers the thing being explained.
            PetAnswerBubbleView(answerText: answerText, theme: theme)
                .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { newSize in
                    answerBubbleSize = newSize
                }
                .opacity(isShowingAnswerBubble ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isShowingAnswerBubble)
                .position(
                    PetOverlayPlacement.centerForBubbleNearHead(
                        headFrame: headFrame,
                        bubbleSize: answerBubbleSize,
                        screenSize: screenSize,
                        avoiding: pointingFrameRectToKeepClear()
                    )
                )
                .animation(followAnimation, value: headFrame)

            // Linger: "⌃⌥ follow up" pill under the head + countdown bar beside it.
            PetFollowUpPillView(theme: theme)
                .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { newSize in
                    followUpPillSize = newSize
                }
                .opacity(phase == .lingering ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: phase == .lingering)
                .position(
                    PetOverlayPlacement.centerForBubbleBelowHead(
                        headFrame: headFrame.offsetBy(dx: 2, dy: 0),
                        bubbleSize: followUpPillSize,
                        screenSize: screenSize
                    )
                )
                .animation(followAnimation, value: headFrame)

            if phase == .lingering {
                PetLingerCountdownBarView(
                    lingerStartDate: petOverlayCoordinator.lingerStartDate,
                    lingerDurationInSeconds: petOverlayCoordinator.lingerDurationInSeconds,
                    theme: theme
                )
                .position(
                    PetOverlayPlacement.centerForPieceBesideHead(
                        headFrame: headFrame,
                        pieceSize: PetLingerCountdownBarView.barSize,
                        screenSize: screenSize,
                        horizontalGapFromHead: 30,
                        topOffsetFromHeadTop: 4
                    )
                )
                .animation(followAnimation, value: headFrame)
                .transition(.opacity)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    @ViewBuilder
    private func pointingLabelChip(headFrame: CGRect, screenSize: CGSize, theme: WaitWhatTheme) -> some View {
        let trimmedLabel = (hootController.detectedElementLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isUsableLabel = !trimmedLabel.isEmpty && trimmedLabel.lowercased() != "none"
        let isPointing = petOverlayCoordinator.phase == .pointingAtTarget
        let targetX = petOverlayCoordinator.pointingTargetInGlobalSpace.map { localPoint(fromGlobalPoint: $0).x } ?? headFrame.midX

        PetPointingLabelChipView(labelText: trimmedLabel.lowercased(), theme: theme)
            .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { newSize in
                pointingLabelChipSize = newSize
            }
            .opacity(isPointing && isUsableLabel ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isPointing)
            .position(
                PetOverlayPlacement.centerForPieceBesideHead(
                    headFrame: headFrame,
                    pieceSize: pointingLabelChipSize,
                    screenSize: screenSize,
                    horizontalGapFromHead: 6,
                    prefersRightSideOfHead: targetX < headFrame.midX
                )
            )
    }

    /// The index-card frame's rect on this screen (depth edge and tab room
    /// included) while hoot flies to or sits at a target, so the bubbles can
    /// stay clear of what is being explained. nil when not pointing.
    private func pointingFrameRectToKeepClear() -> CGRect? {
        let phase = petOverlayCoordinator.phase
        guard phase == .flyingToTarget || phase == .pointingAtTarget,
              let pointingTargetInGlobalSpace = petOverlayCoordinator.pointingTargetInGlobalSpace else { return nil }
        let frameSize = PetPointingFrameView.paddedFrameSize(
            forElementSize: hootController.detectedElementBoxSize,
            screenSize: screenFrame.size
        )
        let targetCenter = localPoint(fromGlobalPoint: pointingTargetInGlobalSpace)
        return CGRect(
            x: targetCenter.x - frameSize.width / 2,
            y: targetCenter.y - frameSize.height / 2 - PetPointingFrameView.roomForTabAboveAndBelow,
            width: frameSize.width + PetPointingFrameView.depthEdgeOutset,
            height: frameSize.height + 2 * PetPointingFrameView.roomForTabAboveAndBelow
        )
    }

    // MARK: - Coordinates

    private func localPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint {
        PetOverlayCoordinateSpace.swiftUIPoint(fromGlobalPoint: globalPoint, inScreenFrame: screenFrame)
    }
}
