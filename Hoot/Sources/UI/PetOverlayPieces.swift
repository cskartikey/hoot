//
//  PetOverlayPieces.swift
//  Hoot
//
//  The small things drawn around hoot's 24pt cursor head (design 4a,
//  "cursor buddy + corner home"):
//    - listening bars + live transcript bubble while ⌃⌥ is held
//    - three thinking dots while the answer is on its way
//    - the answer bubble that follows the cursor while hoot talks
//    - the "⌃⌥ follow up" pill + countdown bar during the linger
//    - the pointing ring and its label chip
//    - the fading dotted trail behind every flight
//  Every color comes from the resolved WaitWhatTheme so light / dark and the
//  chosen mascot re-theme them live.
//

import SwiftUI

// MARK: - Cursor glass

extension View {
    /// The glass used for the small pieces at the cursor: material + theme
    /// tint, 0.5pt hairline, and a lighter shadow than the panels' because
    /// these sit right on top of whatever the learner is reading.
    func petOverlayCursorGlass<GlassShape: InsettableShape>(shape: GlassShape, theme: WaitWhatTheme) -> some View {
        self
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(theme.glassTint)
                }
            )
            .overlay(shape.strokeBorder(theme.foreground(opacity: 0.12), lineWidth: 0.5))
            .clipShape(shape)
            .shadow(color: theme.shadowColor.opacity(theme.panelShadowOpacity * 0.6), radius: 10, x: 0, y: 6)
    }
}

// MARK: - Listening

/// Five 2pt accent2 bars beside the head while ⌃⌥ is held. Heights follow
/// the mic level, shaped like the mock (5, 10, 12, 7, 4 of 12pt), with a
/// faint ripple so they never look frozen during a pause.
struct PetListeningBarsView: View {
    let audioPowerLevel: CGFloat
    let barColor: Color

    static let barsSize = CGSize(width: 5 * 2 + 4 * 2, height: 12)

    private let relativeBarHeights: [CGFloat] = [0.42, 0.83, 1.0, 0.58, 0.33]
    private let tallestBarHeight: CGFloat = 12
    private let shortestBarHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(relativeBarHeights.indices, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(barColor)
                        .frame(width: 2, height: barHeight(barIndex: barIndex, date: timelineContext.date))
                }
            }
            .frame(width: Self.barsSize.width, height: Self.barsSize.height)
        }
    }

    private func barHeight(barIndex: Int, date: Date) -> CGFloat {
        // Mic levels are small numbers; lift and curve them so normal speech fills the bars.
        let boostedLevel = pow(min(max(audioPowerLevel - 0.01, 0) * 3, 1), 0.75)
        let ripplePhase = date.timeIntervalSinceReferenceDate * 3.4 + Double(barIndex) * 0.4
        let idleRipple = CGFloat((sin(ripplePhase) + 1) / 2) * 1.5
        let levelDrivenHeight = boostedLevel * (tallestBarHeight - shortestBarHeight) * relativeBarHeights[barIndex]
        return min(tallestBarHeight, shortestBarHeight + levelDrivenHeight + idleRipple)
    }
}

/// ≈150pt glass bubble under the head with the live transcript
/// (SF 11.5 ink2, 1.35 line height). Draws nothing until words arrive.
struct PetListeningTranscriptBubbleView: View {
    let liveTranscriptText: String
    let theme: WaitWhatTheme

    static let bubbleWidth: CGFloat = 150

    var body: some View {
        Text(liveTranscriptText)
            .font(.system(size: 11.5))
            .foregroundColor(theme.ink2)
            .lineSpacing(2)
            .lineLimit(5)
            // Long questions keep their newest words in view.
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .frame(width: Self.bubbleWidth, alignment: .leading)
            .petOverlayCursorGlass(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), theme: theme)
    }
}

// MARK: - Thinking

/// Three 4pt accent squares beside the head (mock 3a "thinking"), lighting
/// up in turn while the answer is on its way.
struct PetThinkingDotsView: View {
    let dotColor: Color

    static let dotsSize = CGSize(width: 3 * 4 + 2 * 4, height: 4)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.32)) { timelineContext in
            let brightestDotIndex = Int(timelineContext.date.timeIntervalSinceReferenceDate / 0.32) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    Rectangle()
                        .fill(dotColor)
                        .frame(width: 4, height: 4)
                        .opacity(dotIndex == brightestDotIndex ? 1 : 0.35)
                }
            }
            .frame(width: Self.dotsSize.width, height: Self.dotsSize.height)
        }
    }
}

// MARK: - Answer

/// ≈180pt glass bubble under the head while hoot talks: the pet's name
/// (JBM 9.5 muted) over the answer (SF 11.5 ink). The text arrives in step
/// with the voice, so the tail end is what's being said right now.
struct PetAnswerBubbleView: View {
    let answerText: String
    let theme: WaitWhatTheme

    static let bubbleWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(theme.mascot.displayName)
                .font(.jetBrainsMono(9.5, weight: .medium))
                .foregroundColor(theme.muted)

            Text(answerText)
                .font(.system(size: 11.5))
                .foregroundColor(theme.ink)
                .lineSpacing(2)
                .lineLimit(14)
                // Long answers: keep the part being spoken in view.
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(width: Self.bubbleWidth, alignment: .leading)
        .petOverlayCursorGlass(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), theme: theme)
    }
}

// MARK: - Linger

/// Glass capsule under the head during the follow-up window: a small ⌃⌥
/// keycap (JBM 10/600) and "follow up" (JBM 10.5 muted).
struct PetFollowUpPillView: View {
    let theme: WaitWhatTheme

    var body: some View {
        HStack(spacing: 6) {
            Text("⌃⌥")
                .font(.jetBrainsMono(10, weight: .semibold))
                .foregroundColor(theme.ink)
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.solid))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.foreground(opacity: 0.15), lineWidth: 0.5)
                )
            Text("follow up")
                .font(.jetBrainsMono(10.5, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .padding(.vertical, 4)
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .fixedSize()
        .petOverlayCursorGlass(shape: Capsule(style: .continuous), theme: theme)
    }
}

/// 34×3pt accent2 bar beside the head that empties over the linger window.
struct PetLingerCountdownBarView: View {
    let lingerStartDate: Date
    let lingerDurationInSeconds: TimeInterval
    let theme: WaitWhatTheme

    static let barSize = CGSize(width: 34, height: 3)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            let secondsSinceLingerStarted = timelineContext.date.timeIntervalSince(lingerStartDate)
            let remainingFraction = max(0, min(1, 1 - secondsSinceLingerStarted / lingerDurationInSeconds))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.foreground(opacity: 0.10))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.accent2)
                    .frame(width: Self.barSize.width * remainingFraction)
            }
            .frame(width: Self.barSize.width, height: Self.barSize.height)
        }
    }
}

// MARK: - Pointing

/// Drawn around the thing hoot points at: a 2pt accent ring with a 6pt
/// accent@0.25 halo around a radius-7 box. The box is the element's real
/// size when the tutor boxed it ([POINT:x,y,w,h:...]), else a default.
struct PetPointingRingView: View {
    let theme: WaitWhatTheme
    var targetBoxSize: CGSize = PetPointingRingView.defaultTargetBoxSize

    static let defaultTargetBoxSize = CGSize(width: 64, height: 40)
    /// Tiny boxes (a single symbol) still get a ring you can see.
    static let minimumTargetBoxSide: CGFloat = 20
    static let targetBoxCornerRadius: CGFloat = 7
    private static let ringLineWidth: CGFloat = 2
    private static let haloOutset: CGFloat = 6
    /// Breathing room between the element's edge and the ring.
    static let paddingAroundElement: CGFloat = 4

    /// The box the ring is drawn around: the element plus a little padding.
    static func ringBoxSize(forElementSize elementSize: CGSize) -> CGSize {
        CGSize(
            width: max(elementSize.width, minimumTargetBoxSide) + paddingAroundElement * 2,
            height: max(elementSize.height, minimumTargetBoxSide) + paddingAroundElement * 2
        )
    }

    static func outerSize(forElementSize elementSize: CGSize) -> CGSize {
        let ringBox = ringBoxSize(forElementSize: elementSize)
        return CGSize(width: ringBox.width + haloOutset * 2, height: ringBox.height + haloOutset * 2)
    }

    var body: some View {
        let ringBox = Self.ringBoxSize(forElementSize: targetBoxSize)
        let outer = Self.outerSize(forElementSize: targetBoxSize)
        ZStack {
            // Halo: the band between the ring and 6pt outside the box.
            RoundedRectangle(cornerRadius: Self.targetBoxCornerRadius + Self.haloOutset, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.25), lineWidth: Self.haloOutset - Self.ringLineWidth)
                .frame(width: outer.width, height: outer.height)

            // Ring: 2pt right outside the box.
            RoundedRectangle(cornerRadius: Self.targetBoxCornerRadius + Self.ringLineWidth, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: Self.ringLineWidth)
                .frame(width: ringBox.width + Self.ringLineWidth * 2, height: ringBox.height + Self.ringLineWidth * 2)
        }
        .frame(width: outer.width, height: outer.height)
    }
}

/// The label next to the pointing head: JBM 10.5/500, on-accent on accent,
/// radius 5, padding 2/6.
struct PetPointingLabelChipView: View {
    let labelText: String
    let theme: WaitWhatTheme

    var body: some View {
        Text(labelText)
            .font(.jetBrainsMono(10.5, weight: .medium))
            .foregroundColor(theme.onAccent)
            .lineLimit(1)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.accent))
            .fixedSize()
    }
}

// MARK: - Flight trail

/// The dotted trail behind hoot's flights: up to five 4pt accent squares
/// spaced along the path it just flew, strongest right behind hoot and
/// fading further back. `flownPathPositions` are in this screen's SwiftUI
/// coordinates, oldest first.
struct PetFlightTrailView: View {
    let flownPathPositions: [CGPoint]
    let dotColor: Color

    private let distanceBetweenDots: CGFloat = 36
    /// The nearest dot sits this far behind hoot so it peeks out from behind
    /// the sprite instead of under it.
    private let distanceOfFirstDotBehindHoot: CGFloat = 22
    private let dotOpacitiesNearestFirst: [Double] = [0.7, 0.55, 0.42, 0.32, 0.25]
    private let dotSideLength: CGFloat = 4

    var body: some View {
        Canvas { graphicsContext, _ in
            for (dotIndex, dotCenter) in dotCentersWalkingBackAlongPath().enumerated() {
                let dotRect = CGRect(
                    x: dotCenter.x - dotSideLength / 2,
                    y: dotCenter.y - dotSideLength / 2,
                    width: dotSideLength,
                    height: dotSideLength
                )
                graphicsContext.fill(Path(dotRect), with: .color(dotColor.opacity(dotOpacitiesNearestFirst[dotIndex])))
            }
        }
        .allowsHitTesting(false)
    }

    /// Walks back from the newest position, dropping a dot every
    /// `distanceBetweenDots` of path length.
    private func dotCentersWalkingBackAlongPath() -> [CGPoint] {
        guard flownPathPositions.count >= 2 else { return [] }

        var dotCenters: [CGPoint] = []
        var pathLengthUntilNextDot = distanceOfFirstDotBehindHoot
        var newerPointIndex = flownPathPositions.count - 1

        while newerPointIndex > 0 && dotCenters.count < dotOpacitiesNearestFirst.count {
            var segmentNewerEnd = flownPathPositions[newerPointIndex]
            let segmentOlderEnd = flownPathPositions[newerPointIndex - 1]
            var unwalkedSegmentLength = hypot(segmentNewerEnd.x - segmentOlderEnd.x, segmentNewerEnd.y - segmentOlderEnd.y)

            while unwalkedSegmentLength > 0
                    && unwalkedSegmentLength >= pathLengthUntilNextDot
                    && dotCenters.count < dotOpacitiesNearestFirst.count {
                let fractionTowardOlderEnd = pathLengthUntilNextDot / unwalkedSegmentLength
                let dotCenter = CGPoint(
                    x: segmentNewerEnd.x + (segmentOlderEnd.x - segmentNewerEnd.x) * fractionTowardOlderEnd,
                    y: segmentNewerEnd.y + (segmentOlderEnd.y - segmentNewerEnd.y) * fractionTowardOlderEnd
                )
                dotCenters.append(dotCenter)
                segmentNewerEnd = dotCenter
                unwalkedSegmentLength -= pathLengthUntilNextDot
                pathLengthUntilNextDot = distanceBetweenDots
            }

            pathLengthUntilNextDot -= unwalkedSegmentLength
            newerPointIndex -= 1
        }

        return dotCenters
    }
}
