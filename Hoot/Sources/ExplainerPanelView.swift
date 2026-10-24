//
//  ExplainerPanelView.swift
//  Hoot
//
//  SwiftUI content of the floating explainer-video panel (handoff screen 7).
//  A 318pt glass card with three states:
//    - rendering: striped placeholder with a stage pill, title + ETA, and a
//      4-segment progress bar (script · voice · animate · stitch)
//    - playing: chrome-less video with an accent scrubber, synced caption,
//      and a controls row (play/pause, time, "follow up ⌃⌥" hint, bookmark),
//      with the pet perched on the card's top edge in its presenting state
//    - sketch: the animated SVG page in a web view, the question as the
//      caption, and a controls row ("draw again", follow-up hint, big window)
//    - failed: a short friendly message with "try again"
//  Every color comes from WaitWhatThemeStore so light/dark and the mascot's
//  accents apply live.
//

import AVKit
import SwiftUI

struct ExplainerPanelView: View {
    @ObservedObject var explainerPanelManager: ExplainerPanelManager
    @ObservedObject private var themeStore = WaitWhatThemeStore.shared

    @State private var isHoveringCard = false

    /// Video playing or sketch showing: the pet perches on the card.
    private var isPlayingPhase: Bool {
        explainerPanelManager.explainerPanelPhase.isShowingAPicture
    }

    var body: some View {
        let theme = themeStore.theme

        ZStack(alignment: .topLeading) {
            explainerCard(theme: theme)
                .padding(.top, isPlayingPhase ? ExplainerPanelManager.presentingPetOverhangAboveCard : 0)

            // The pet sits on the card's top edge while the video plays, its
            // feet overlapping the border, drawn in front of the card.
            if isPlayingPhase {
                PetSpriteView(state: .presenting, scale: 4)
                    .padding(.leading, ExplainerPanelManager.presentingPetInsetFromCardLeadingEdge)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(width: ExplainerPanelManager.explainerCardWidth)
        .padding(.horizontal, ExplainerPanelManager.shadowPaddingOnSides)
        .padding(.top, ExplainerPanelManager.shadowPaddingAboveCard)
        .padding(.bottom, ExplainerPanelManager.shadowPaddingBelowCard)
        .fixedSize(horizontal: false, vertical: true)
        // Report the natural height so the manager can size the window to fit.
        .onGeometryChange(for: CGFloat.self) { geometryProxy in
            geometryProxy.size.height
        } action: { naturalContentHeight in
            explainerPanelManager.resizePanelToFitContent(contentHeight: naturalContentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.3), value: isPlayingPhase)
    }

    // MARK: - Card

    private func explainerCard(theme: WaitWhatTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch explainerPanelManager.explainerPanelPhase {
            case .generatingVideo:
                ExplainerRenderingStateView(explainerPanelManager: explainerPanelManager, theme: theme)
                    .transition(.opacity)
            case .playingVideo:
                ExplainerPlayingStateView(explainerPanelManager: explainerPanelManager, theme: theme)
                    .transition(.opacity)
            case .showingSketch(let finishedSketch):
                ExplainerSketchShowingStateView(
                    explainerPanelManager: explainerPanelManager,
                    finishedSketch: finishedSketch,
                    theme: theme
                )
                .transition(.opacity)
            case .failed(let friendlyErrorMessage):
                ExplainerFailedStateView(
                    friendlyErrorMessage: friendlyErrorMessage,
                    theme: theme,
                    onTryAgain: { explainerPanelManager.retryMostRecentRequest() },
                    onClose: { explainerPanelManager.close() }
                )
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(width: ExplainerPanelManager.explainerCardWidth, alignment: .leading)
        .waitWhatGlassPanel(theme: theme, cornerRadius: 16)
        // Close button appears on hover, top-right over the placeholder /
        // video, so the resting card matches the design while mouse users
        // still have a way to dismiss it besides Esc.
        .overlay(alignment: .topTrailing) {
            if isHoveringCard {
                ExplainerCloseButton(theme: theme) {
                    explainerPanelManager.close()
                }
                .padding(18)
                .transition(.opacity)
            }
        }
        .onHover { isHoveringNow in
            withAnimation(.easeOut(duration: 0.15)) { isHoveringCard = isHoveringNow }
        }
        .animation(.easeInOut(duration: 0.25), value: explainerPanelManager.explainerPanelPhase)
    }
}

// MARK: - Rendering state

private struct ExplainerRenderingStateView: View {
    @ObservedObject var explainerPanelManager: ExplainerPanelManager
    let theme: WaitWhatTheme

    var body: some View {
        // Ticks a few times a second so the ETA counts down and the active
        // segment fills between studio events.
        TimelineView(.periodic(from: .now, by: 0.25)) { timelineContext in
            let renderingProgress = estimatedRenderingProgress(at: timelineContext.date)

            VStack(alignment: .leading, spacing: 10) {
                // While the video renders, the buddy and a friend play catch;
                // the stage pill sits above them.
                ZStack(alignment: .top) {
                    ExplainerPlaytimeView(theme: theme)
                    ExplainerStagePill(stagePillText: renderingProgress.stagePillText, theme: theme)
                        .padding(.top, 12)
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(explainerTitleText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(renderingProgress.etaText)
                        .font(.jetBrainsMono(11))
                        .foregroundColor(theme.faint)
                        .monospacedDigit()
                }

                if explainerPanelManager.isActiveJobASketch {
                    // A sketch is one call: a single segment filling over the
                    // typical wait, in place of the studio's four stages.
                    VStack(spacing: 6) {
                        ExplainerProgressSegment(
                            fillFraction: renderingProgress.activeStepFillFraction,
                            isActiveSegment: true,
                            theme: theme
                        )
                        HStack(spacing: 0) {
                            Text("sketch")
                                .font(.jetBrainsMono(10.5))
                                .foregroundColor(theme.ink)
                            Spacer(minLength: 0)
                            Text("quick, no narration")
                                .font(.jetBrainsMono(10.5))
                                .foregroundColor(theme.faint)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(ExplainerProgressStep.allCases, id: \.rawValue) { progressStep in
                                ExplainerProgressSegment(
                                    fillFraction: segmentFillFraction(
                                        for: progressStep,
                                        activeProgressStep: renderingProgress.activeProgressStep,
                                        activeStepFillFraction: renderingProgress.activeStepFillFraction
                                    ),
                                    isActiveSegment: progressStep == renderingProgress.activeProgressStep,
                                    theme: theme
                                )
                            }
                        }

                        HStack(spacing: 0) {
                            ForEach(ExplainerProgressStep.allCases, id: \.rawValue) { progressStep in
                                if progressStep != .script { Spacer(minLength: 0) }
                                Text(progressStep.segmentLabel)
                                    .font(.jetBrainsMono(10.5))
                                    .foregroundColor(progressStep == renderingProgress.activeProgressStep ? theme.ink : theme.faint)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The studio's title once the script exists, otherwise the question.
    private var explainerTitleText: String {
        let titleText = explainerPanelManager.studioScriptTitleText ?? explainerPanelManager.currentQuestionText
        if titleText.isEmpty {
            return explainerPanelManager.isActiveJobASketch ? "sketching this out" : "making you a video"
        }
        return titleText.lowercased()
    }

    private struct EstimatedRenderingProgress {
        let activeProgressStep: ExplainerProgressStep
        let activeStepFillFraction: Double
        let stagePillText: String
        let etaText: String
    }

    /// Turns the latest studio stage and the clock into what the card shows.
    /// The studio emits no event for the final mux, so once animating has run
    /// about as long as a render usually takes, we show "stitch" as active.
    private func estimatedRenderingProgress(at currentDate: Date) -> EstimatedRenderingProgress {
        if explainerPanelManager.isActiveJobASketch {
            return estimatedSketchProgress(at: currentDate)
        }
        let isFixingAnimation = explainerPanelManager.currentRenderAttemptNumber > 1
        // A fix round is one LLM call plus one render, a bit faster than the first pass.
        let expectedAnimateDurationInSeconds: Double = isFixingAnimation ? 22 : ExplainerProgressStep.animate.typicalDurationInSeconds

        func expectedDuration(of progressStep: ExplainerProgressStep) -> Double {
            progressStep == .animate ? expectedAnimateDurationInSeconds : progressStep.typicalDurationInSeconds
        }

        var activeProgressStep = explainerPanelManager.latestReportedProgressStep
        var secondsElapsedInActiveStep = max(0, currentDate.timeIntervalSince(explainerPanelManager.latestReportedProgressStepStartedDate))
        if activeProgressStep == .animate && secondsElapsedInActiveStep > expectedAnimateDurationInSeconds {
            activeProgressStep = .stitch
            secondsElapsedInActiveStep -= expectedAnimateDurationInSeconds
        }

        let expectedActiveStepDuration = expectedDuration(of: activeProgressStep)
        // Never show the active segment empty or complete: it's in progress.
        let activeStepFillFraction = min(0.92, max(0.06, secondsElapsedInActiveStep / expectedActiveStepDuration))

        let secondsLeftInActiveStep = max(1, expectedActiveStepDuration - secondsElapsedInActiveStep)
        let secondsForLaterSteps = ExplainerProgressStep.allCases
            .filter { $0.rawValue > activeProgressStep.rawValue }
            .reduce(0) { $0 + expectedDuration(of: $1) }
        let estimatedSecondsRemaining = Int((secondsLeftInActiveStep + secondsForLaterSteps).rounded(.up))
        let isPastEstimateForLastStep = activeProgressStep == .stitch
            && secondsElapsedInActiveStep > expectedActiveStepDuration
        let etaText = isPastEstimateForLastStep ? "almost" : "~\(estimatedSecondsRemaining)s"

        let stagePillText: String
        if explainerPanelManager.isWaitingForFirstStudioStage {
            stagePillText = "getting ready"
        } else {
            switch activeProgressStep {
            case .script: stagePillText = "writing the script"
            case .voice: stagePillText = "recording the voice"
            case .animate: stagePillText = isFixingAnimation ? "fixing the animation" : "animating"
            case .stitch: stagePillText = "stitching it together"
            }
        }

        return EstimatedRenderingProgress(
            activeProgressStep: activeProgressStep,
            activeStepFillFraction: activeStepFillFraction,
            stagePillText: stagePillText,
            etaText: etaText
        )
    }

    /// A sketch has no stage events: the fill and ETA come from the clock
    /// against the typical wait. Past the estimate the pill says so rather
    /// than inventing a countdown.
    private func estimatedSketchProgress(at currentDate: Date) -> EstimatedRenderingProgress {
        let typicalSketchDuration = ExplainerPanelManager.typicalSketchDurationInSeconds
        let secondsElapsed = max(0, currentDate.timeIntervalSince(explainerPanelManager.sketchJobStartedDate))
        let fillFraction = min(0.92, max(0.06, secondsElapsed / typicalSketchDuration))
        let secondsRemaining = Int((typicalSketchDuration - secondsElapsed).rounded(.up))
        let isPastEstimate = secondsElapsed > typicalSketchDuration
        return EstimatedRenderingProgress(
            activeProgressStep: .script,
            activeStepFillFraction: fillFraction,
            stagePillText: isPastEstimate ? "almost there" : "sketching",
            etaText: isPastEstimate ? "almost" : "~\(max(1, secondsRemaining))s"
        )
    }

    private func segmentFillFraction(
        for progressStep: ExplainerProgressStep,
        activeProgressStep: ExplainerProgressStep,
        activeStepFillFraction: Double
    ) -> Double {
        if progressStep.rawValue < activeProgressStep.rawValue { return 1 }
        if progressStep == activeProgressStep { return activeStepFillFraction }
        return 0
    }
}

/// One 4pt progress segment: done = accent2, active = accent partial fill,
/// to-do = fg@0.08 track.
private struct ExplainerProgressSegment: View {
    let fillFraction: Double
    let isActiveSegment: Bool
    let theme: WaitWhatTheme

    var body: some View {
        GeometryReader { geometryProxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.foreground(opacity: 0.08))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isActiveSegment ? theme.accent : theme.accent2)
                    .frame(width: geometryProxy.size.width * fillFraction)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.25), value: fillFraction)
    }
}

/// The centered status pill on the placeholder: an 8pt pixel spinner
/// (so the card feels alive) + the current stage.
private struct ExplainerStagePill: View {
    let stagePillText: String
    let theme: WaitWhatTheme

    var body: some View {
        HStack(spacing: 8) {
            ExplainerPixelSpinnerView(pixelColor: theme.accent)
            Text(stagePillText)
                .font(.jetBrainsMono(11.5, weight: .medium))
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .id(stagePillText)
                .transition(.opacity)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(theme.pill)
                .shadow(color: theme.foreground(opacity: 0.08), radius: 4, x: 0, y: 2)
        )
        .animation(.easeInOut(duration: 0.2), value: stagePillText)
    }
}

/// A 3×3 ring of 2pt pixels (8pt overall, the size of the old dot) with one
/// bright pixel chasing round it and a short fading tail, stepping every
/// 100ms. Driven by a TimelineView rather than `repeatForever`, which
/// stuttered whenever the stage text swapped out from under it.
private struct ExplainerPixelSpinnerView: View {
    let pixelColor: Color

    private static let pixelSide: CGFloat = 2
    private static let pixelGap: CGFloat = 1
    private static let stepDurationInSeconds: TimeInterval = 0.1
    /// Grid positions (column, row) around the ring, clockwise from top-left.
    private static let ringPositions: [(column: Int, row: Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.stepDurationInSeconds)) { timelineContext in
            let headStep = Int(timelineContext.date.timeIntervalSinceReferenceDate / Self.stepDurationInSeconds)
                % Self.ringPositions.count
            Canvas { graphicsContext, _ in
                for (ringIndex, ringPosition) in Self.ringPositions.enumerated() {
                    // 0 = the head, 1 and 2 = the fading tail behind it.
                    let stepsBehindHead = (headStep - ringIndex + Self.ringPositions.count) % Self.ringPositions.count
                    let pixelOpacity: Double
                    switch stepsBehindHead {
                    case 0: pixelOpacity = 1
                    case 1: pixelOpacity = 0.55
                    case 2: pixelOpacity = 0.25
                    default: pixelOpacity = 0.1
                    }
                    let pitch = Self.pixelSide + Self.pixelGap
                    let pixelRect = CGRect(
                        x: CGFloat(ringPosition.column) * pitch,
                        y: CGFloat(ringPosition.row) * pitch,
                        width: Self.pixelSide,
                        height: Self.pixelSide
                    )
                    graphicsContext.fill(Path(pixelRect), with: .color(pixelColor.opacity(pixelOpacity)))
                }
            }
            .frame(width: 3 * Self.pixelSide + 2 * Self.pixelGap, height: 3 * Self.pixelSide + 2 * Self.pixelGap)
        }
    }
}

/// CSS `repeating-linear-gradient(135deg, A 0 10px, B 10px 20px)`: bands of
/// equal width running bottom-left to top-right.
private struct DiagonalStripesBackground: View {
    let stripeColorA: Color
    let stripeColorB: Color
    let stripeBandWidth: CGFloat

    var body: some View {
        Canvas { graphicsContext, canvasSize in
            graphicsContext.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(stripeColorA))

            // Lines x + y = c are perpendicular to the 135° gradient direction.
            // A band of width w measured along that direction spans w·√2 in c.
            let bandSpanAlongXPlusY = stripeBandWidth * 2.0.squareRoot()
            let largestXPlusY = canvasSize.width + canvasSize.height
            var bandStartXPlusY = bandSpanAlongXPlusY
            while bandStartXPlusY < largestXPlusY {
                let bandEndXPlusY = bandStartXPlusY + bandSpanAlongXPlusY
                var stripePath = Path()
                stripePath.move(to: CGPoint(x: bandStartXPlusY, y: 0))
                stripePath.addLine(to: CGPoint(x: bandEndXPlusY, y: 0))
                stripePath.addLine(to: CGPoint(x: 0, y: bandEndXPlusY))
                stripePath.addLine(to: CGPoint(x: 0, y: bandStartXPlusY))
                stripePath.closeSubpath()
                graphicsContext.fill(stripePath, with: .color(stripeColorB))
                bandStartXPlusY += bandSpanAlongXPlusY * 2
            }
        }
    }
}

// MARK: - Playing state

private struct ExplainerPlayingStateView: View {
    @ObservedObject var explainerPanelManager: ExplainerPanelManager
    let theme: WaitWhatTheme

    /// Two caption lines at SF 14 / 1.45, reserved so the card doesn't jump
    /// in height as captions change.
    private let reservedCaptionHeight: CGFloat = 41

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            videoWithScrubber

            Text(explainerPanelManager.currentCaptionText ?? "")
                .font(.system(size: 14))
                .lineSpacing(3.5)
                .foregroundColor(theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: reservedCaptionHeight, alignment: .topLeading)
                .id(explainerPanelManager.currentCaptionText)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: explainerPanelManager.currentCaptionText)

            controlsRow
        }
    }

    private var videoWithScrubber: some View {
        ZStack(alignment: .bottom) {
            // Manim renders on a dark background; black letterboxing blends in.
            Color.black

            if let explainerVideoPlayer = explainerPanelManager.explainerVideoPlayer {
                ChromelessVideoPlayerView(explainerVideoPlayer: explainerVideoPlayer)
            }

            GeometryReader { geometryProxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: geometryProxy.size.width * playbackFraction)
                }
            }
            .frame(height: 3)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            ExplainerControlIconButton(
                systemImageName: playPauseSystemImageName,
                iconPointSize: 22,
                iconColor: theme.ink,
                accessibilityLabel: playPauseAccessibilityLabel
            ) {
                explainerPanelManager.togglePlayPauseOrReplay()
            }

            Text("\(Self.formattedPlaybackTime(explainerPanelManager.currentPlaybackTimeInSeconds)) / \(Self.formattedPlaybackTime(explainerPanelManager.finishedVideoDurationInSeconds))")
                .font(.jetBrainsMono(11))
                .foregroundColor(theme.muted)
                .monospacedDigit()

            Spacer(minLength: 4)

            // A hint, not a button: holding ⌃⌥ is how you follow up.
            Text("follow up ⌃⌥")
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Capsule().fill(theme.foreground(opacity: 0.05)))

            ExplainerControlIconButton(
                systemImageName: "arrow.up.left.and.arrow.down.right",
                iconPointSize: 15,
                iconColor: theme.muted,
                accessibilityLabel: "Open the video big"
            ) {
                explainerPanelManager.openExplainerVideoInLargeWindow()
            }

            ExplainerControlIconButton(
                systemImageName: explainerPanelManager.isCurrentVideoBookmarked ? "bookmark.fill" : "bookmark",
                iconPointSize: 18,
                iconColor: explainerPanelManager.isCurrentVideoBookmarked ? theme.accent : theme.muted,
                accessibilityLabel: explainerPanelManager.isCurrentVideoBookmarked ? "Remove bookmark" : "Bookmark"
            ) {
                explainerPanelManager.toggleCurrentVideoBookmark()
            }
        }
    }

    private var playbackFraction: Double {
        let videoDuration = explainerPanelManager.finishedVideoDurationInSeconds
        guard videoDuration > 0 else { return 0 }
        return min(1, max(0, explainerPanelManager.currentPlaybackTimeInSeconds / videoDuration))
    }

    private var playPauseSystemImageName: String {
        if explainerPanelManager.hasVideoFinishedPlaying { return "arrow.counterclockwise.circle.fill" }
        return explainerPanelManager.isVideoPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private var playPauseAccessibilityLabel: String {
        if explainerPanelManager.hasVideoFinishedPlaying { return "Replay" }
        return explainerPanelManager.isVideoPlaying ? "Pause" : "Play"
    }

    /// 14.2 → "0:14", 75 → "1:15".
    private static func formattedPlaybackTime(_ timeInSeconds: Double) -> String {
        let wholeSeconds = timeInSeconds.isFinite ? max(0, Int(timeInSeconds.rounded(.down))) : 0
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

// MARK: - Sketch state

/// The finished sketch on the card: the web view where the video would be,
/// the question as the caption, and a controls row. No scrubber or time,
/// since the page loops on its own.
private struct ExplainerSketchShowingStateView: View {
    @ObservedObject var explainerPanelManager: ExplainerPanelManager
    let finishedSketch: ExplainerFinishedSketch
    let theme: WaitWhatTheme

    /// Matches the video state's reserved caption height so the card is the
    /// same size whichever kind of picture it holds.
    private let reservedCaptionHeight: CGFloat = 41

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                // A faint paper tint behind the transparent page, so the
                // sketch reads as a framed picture rather than floating text.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.foreground(opacity: 0.04))
                ExplainerSketchView(sketchFileURL: finishedSketch.fileURL)
                    .padding(6)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.foreground(opacity: 0.10), lineWidth: 1)
            )

            Text(explainerPanelManager.currentCaptionText ?? finishedSketch.question.lowercased())
                .font(.system(size: 14))
                .lineSpacing(3.5)
                .foregroundColor(theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: reservedCaptionHeight, alignment: .topLeading)

            controlsRow
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            // Sketches are cheap: redrawing is the natural "not quite" fix.
            ExplainerControlIconButton(
                systemImageName: "arrow.counterclockwise.circle.fill",
                iconPointSize: 22,
                iconColor: theme.ink,
                accessibilityLabel: "Draw it again"
            ) {
                explainerPanelManager.retryMostRecentRequest()
            }

            Text("sketch")
                .font(.jetBrainsMono(11))
                .foregroundColor(theme.muted)

            Spacer(minLength: 4)

            // A hint, not a button: holding ⌃⌥ is how you follow up.
            Text("follow up ⌃⌥")
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Capsule().fill(theme.foreground(opacity: 0.05)))

            ExplainerControlIconButton(
                systemImageName: "arrow.up.left.and.arrow.down.right",
                iconPointSize: 15,
                iconColor: theme.muted,
                accessibilityLabel: "Open the sketch big"
            ) {
                explainerPanelManager.openExplainerVideoInLargeWindow()
            }

            ExplainerControlIconButton(
                systemImageName: explainerPanelManager.isCurrentVideoBookmarked ? "bookmark.fill" : "bookmark",
                iconPointSize: 18,
                iconColor: explainerPanelManager.isCurrentVideoBookmarked ? theme.accent : theme.muted,
                accessibilityLabel: explainerPanelManager.isCurrentVideoBookmarked ? "Remove bookmark" : "Bookmark"
            ) {
                explainerPanelManager.toggleCurrentVideoBookmark()
            }
        }
    }
}

// MARK: - Failed state

private struct ExplainerFailedStateView: View {
    let friendlyErrorMessage: String
    let theme: WaitWhatTheme
    let onTryAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                DiagonalStripesBackground(
                    stripeColorA: theme.placeholderStripeA,
                    stripeColorB: theme.placeholderStripeB,
                    stripeBandWidth: 10
                )
                VStack(spacing: 4) {
                    PetSpriteView(state: .thinking, scale: 2)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(theme.faint)
                            .frame(width: 8, height: 8)
                        Text("couldn't draw this one")
                            .font(.jetBrainsMono(11.5, weight: .medium))
                            .foregroundColor(theme.ink)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule()
                            .fill(theme.pill)
                            .shadow(color: theme.foreground(opacity: 0.08), radius: 4, x: 0, y: 2)
                    )
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(friendlyErrorMessage)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundColor(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("esc to close")
                    .font(.jetBrainsMono(11))
                    .foregroundColor(theme.faint)
                Spacer(minLength: 4)
                ExplainerPillButton(title: "close", isPrimary: false, theme: theme, buttonAction: onClose)
                ExplainerPillButton(title: "try again", isPrimary: true, theme: theme, buttonAction: onTryAgain)
            }
        }
    }
}

// MARK: - Buttons

/// SF Symbol button for the controls row. Pointer cursor plus a slight
/// brighten on hover so it reads as clickable.
private struct ExplainerControlIconButton: View {
    let systemImageName: String
    let iconPointSize: CGFloat
    let iconColor: Color
    let accessibilityLabel: String
    let buttonAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: buttonAction) {
            Image(systemName: systemImageName)
                .font(.system(size: iconPointSize))
                .foregroundColor(iconColor)
                .opacity(isHovering ? 0.75 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHoveringNow in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = isHoveringNow }
        }
        .pointerCursor()
    }
}

/// Capsule button for the error state. Primary = accent fill with on-accent
/// text (like onboarding's "allow"); secondary = fg@0.05 fill.
private struct ExplainerPillButton: View {
    let title: String
    let isPrimary: Bool
    let theme: WaitWhatTheme
    let buttonAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: buttonAction) {
            Text(title)
                .font(.jetBrainsMono(11.5, weight: .semibold))
                .foregroundColor(isPrimary ? theme.onAccent : theme.ink)
                .padding(.vertical, 4)
                .padding(.horizontal, 11)
                .background(
                    Capsule().fill(
                        isPrimary
                            ? theme.accent.opacity(isHovering ? 0.88 : 1)
                            : theme.foreground(opacity: isHovering ? 0.10 : 0.05)
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNow in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = isHoveringNow }
        }
        .pointerCursor()
    }
}

/// Small round close button shown while the card is hovered.
private struct ExplainerCloseButton: View {
    let theme: WaitWhatTheme
    let buttonAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: buttonAction) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.pill))
                .overlay(Circle().strokeBorder(theme.foreground(opacity: isHovering ? 0.2 : 0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { isHoveringNow in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = isHoveringNow }
        }
        .pointerCursor()
    }
}

// MARK: - Video

/// AVPlayerView with every control hidden: the panel provides its own
/// controls row, scrubber and captions, so the video stays clean.
private struct ChromelessVideoPlayerView: NSViewRepresentable {
    let explainerVideoPlayer: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.player = explainerVideoPlayer
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== explainerVideoPlayer {
            playerView.player = explainerVideoPlayer
        }
    }
}
