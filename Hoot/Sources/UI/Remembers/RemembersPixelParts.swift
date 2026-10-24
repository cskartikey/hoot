//
//  RemembersPixelParts.swift
//  Hoot
//
//  The pixel-styled memory objects of the remembers window (design
//  "pixel parts"): the notched index card, the "due now" tab, the review
//  ladder (small on cards, big with the pet in the detail), the result
//  glyphs and the dashed ghost card. No radius, no blur; everything else in
//  the window is native.
//

import SwiftUI

// MARK: - Window tokens

extension WaitWhatTheme {
    /// Index-card fill and the answer quote box.
    var cardSolid: Color { isDark ? Color(hex: "#323235") : .white }
    /// Accent laid over `cardSolid` for a due card (8% light / 14% dark).
    var dueFillAccentOpacity: Double { isDark ? 0.14 : 0.08 }
    var dueDepth: Color { accent.opacity(isDark ? 0.45 : 0.35) }
    /// Background of a search match.
    var searchHighlight: Color { accent2.opacity(isDark ? 0.32 : 0.22) }
}

// MARK: - Notched shapes

/// A rectangle with a 2×2 square bitten out of each corner (the design's
/// 1-step notch). `notchesBottomCorners: false` for the due tab.
struct PixelNotchedRectangle: Shape {
    var notchSize: CGFloat = 2
    var notchesBottomCorners = true

    func path(in rect: CGRect) -> Path {
        let notch = notchSize
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY + notch))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notch))
        if notchesBottomCorners {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - notch))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + notch))
        path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.minY + notch))
        path.closeSubpath()
        return path
    }
}

// MARK: - Index card

/// Frame 2pt + inner fill + the same notched shape offset +2,+2 behind as
/// depth. Due cards use the accent frame, accent-tinted fill and the
/// "due now" tab.
struct RemembersIndexCardBackground: View {
    let isDue: Bool
    let theme: WaitWhatTheme

    var body: some View {
        ZStack {
            PixelNotchedRectangle()
                .fill(isDue ? theme.dueDepth : theme.foreground(opacity: 0.06))
                .offset(x: 2, y: 2)
            PixelNotchedRectangle()
                .fill(isDue ? theme.accent : theme.foreground(opacity: 0.10))
            ZStack {
                Rectangle().fill(theme.cardSolid)
                if isDue {
                    Rectangle().fill(theme.accent.opacity(theme.dueFillAccentOpacity))
                }
            }
            .padding(2)
        }
    }
}

extension View {
    /// Puts the content on an index card; due cards get the tab at top-left.
    func remembersIndexCard(isDue: Bool, theme: WaitWhatTheme) -> some View {
        background(RemembersIndexCardBackground(isDue: isDue, theme: theme))
            .overlay(alignment: .topLeading) {
                if isDue {
                    RemembersDueTab(theme: theme)
                        .offset(x: 8, y: -16)
                }
            }
    }
}

/// "due now" on an accent tab whose bottom 2pt overlap the card frame.
/// Rises 4pt → 0 in two steps when it appears, like the pointing tab.
struct RemembersDueTab: View {
    let theme: WaitWhatTheme
    @State private var riseOffset: CGFloat = 4

    var body: some View {
        Text("due now")
            .font(.jetBrainsMono(10.5, weight: .semibold))
            .foregroundColor(theme.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.bottom, 2)
            .frame(height: 18)
            .background(PixelNotchedRectangle(notchesBottomCorners: false).fill(theme.accent))
            .offset(y: riseOffset)
            .onAppear {
                riseOffset = 4
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { riseOffset = 2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { riseOffset = 0 }
            }
    }
}

// MARK: - Review ladder

/// Color of one ladder step: climbed → accent2, waiting on → accent,
/// not yet → fg@0.10. Learned (stage 4) → every step accent2.
private func ladderStepColor(stepIndex: Int, displayedStage: Int, theme: WaitWhatTheme) -> Color {
    if displayedStage >= RemembersWindowModel.ladderStepCount || stepIndex < displayedStage { return theme.accent2 }
    if stepIndex == displayedStage { return theme.accent }
    return theme.foreground(opacity: 0.10)
}

private func ladderLabelColor(stepIndex: Int, displayedStage: Int, theme: WaitWhatTheme) -> Color {
    stepIndex == displayedStage ? theme.ink : theme.faint
}

/// Card ladder: 4 steps 22pt wide, gap 2, heights 4/8/12/16, labels below.
struct RemembersSmallReviewLadder: View {
    /// 0–3, or 4 when learned; nil draws the empty (ghost card) ladder.
    let displayedStage: Int?
    let theme: WaitWhatTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<RemembersWindowModel.ladderStepCount, id: \.self) { stepIndex in
                    Rectangle()
                        .fill(stepColor(stepIndex))
                        .frame(width: 22, height: CGFloat(4 + stepIndex * 4))
                }
            }
            .frame(height: 16, alignment: .bottom)
            HStack(spacing: 2) {
                ForEach(0..<RemembersWindowModel.ladderStepCount, id: \.self) { stepIndex in
                    Text(RemembersWindowModel.shortLadderLabels[stepIndex])
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(labelColor(stepIndex))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 22)
                }
            }
        }
        .animation(.easeInOut(duration: 0.08), value: displayedStage)
    }

    private func stepColor(_ stepIndex: Int) -> Color {
        guard let displayedStage else { return theme.foreground(opacity: 0.10) }
        return ladderStepColor(stepIndex: stepIndex, displayedStage: displayedStage, theme: theme)
    }

    private func labelColor(_ stepIndex: Int) -> Color {
        guard let displayedStage else { return theme.faint }
        return ladderLabelColor(stepIndex: stepIndex, displayedStage: displayedStage, theme: theme)
    }
}

/// Detail ladder: steps 52pt wide, gap 4, heights 8/16/24/32 in an 84pt
/// area, with the pet (48pt) standing on the current step.
struct RemembersBigReviewLadder: View {
    let displayedStage: Int
    let petState: PetAnimationState
    let theme: WaitWhatTheme

    private let stepWidth: CGFloat = 52
    private let stepGap: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: stepGap) {
                    ForEach(0..<RemembersWindowModel.ladderStepCount, id: \.self) { stepIndex in
                        Rectangle()
                            .fill(ladderStepColor(stepIndex: stepIndex, displayedStage: displayedStage, theme: theme))
                            .frame(width: stepWidth, height: stepHeight(stepIndex))
                    }
                }
                PetSpriteView(state: petState, scale: 2)
                    // The sprite's bottom row is its shadow, so it sinks 2pt into the step.
                    .offset(x: CGFloat(petStepIndex) * (stepWidth + stepGap) + 2,
                            y: -(stepHeight(petStepIndex) - 2))
            }
            .frame(height: 84, alignment: .bottomLeading)
            HStack(spacing: stepGap) {
                ForEach(0..<RemembersWindowModel.ladderStepCount, id: \.self) { stepIndex in
                    Text(RemembersWindowModel.longLadderLabels[stepIndex])
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(ladderLabelColor(stepIndex: stepIndex, displayedStage: displayedStage, theme: theme))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: stepWidth)
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: displayedStage)
    }

    private var petStepIndex: Int {
        min(displayedStage, RemembersWindowModel.ladderStepCount - 1)
    }

    private func stepHeight(_ stepIndex: Int) -> CGFloat {
        CGFloat(8 + stepIndex * 8)
    }
}

// MARK: - Result glyph

/// 8×8, shape-coded so it reads for every mascot and for color blindness:
/// remembered = solid notched accent2 · shaky = 2pt checker + hairline ·
/// forgot = hollow 2pt square · not checked yet = a dash.
struct RemembersResultGlyph: View {
    let reviewResult: ReviewResult?
    let theme: WaitWhatTheme

    var body: some View {
        Group {
            switch reviewResult {
            case .remembered:
                PixelNotchedRectangle().fill(theme.accent2)
                    .frame(width: 8, height: 8)
            case .shaky:
                Canvas { graphicsContext, _ in
                    for rowIndex in 0..<4 {
                        for columnIndex in 0..<4 where (rowIndex + columnIndex) % 2 == 0 {
                            let cellRect = CGRect(x: CGFloat(columnIndex) * 2, y: CGFloat(rowIndex) * 2, width: 2, height: 2)
                            graphicsContext.fill(Path(cellRect), with: .color(theme.accent2))
                        }
                    }
                }
                .frame(width: 8, height: 8)
                .overlay(Rectangle().strokeBorder(theme.accent2, lineWidth: 0.5))
            case .forgot:
                Rectangle().strokeBorder(theme.muted, lineWidth: 2)
                    .frame(width: 8, height: 8)
            case nil:
                Rectangle().fill(theme.faint)
                    .frame(width: 8, height: 2)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Ghost card (empty state)

/// "your first idea": dashed 2pt frame (4 on / 4 off), faint depth, empty ladder.
struct RemembersGhostCard: View {
    let theme: WaitWhatTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("your first idea")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.faint)
            HStack(alignment: .bottom) {
                RemembersSmallReviewLadder(displayedStage: nil, theme: theme)
                Spacer(minLength: 8)
                Text("lands here")
                    .font(.jetBrainsMono(11, weight: .medium))
                    .foregroundColor(theme.faint)
            }
        }
        .padding(.top, 13)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: 234, alignment: .leading)
        .background(
            ZStack {
                PixelNotchedRectangle()
                    .fill(theme.foreground(opacity: 0.04))
                    .offset(x: 2, y: 2)
                Rectangle()
                    .strokeBorder(theme.foreground(opacity: 0.16), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }
        )
    }
}

/// 8pt notched accent square before "2 due now" in the header.
struct RemembersDueIndicatorSquare: View {
    let theme: WaitWhatTheme

    var body: some View {
        PixelNotchedRectangle().fill(theme.accent)
            .frame(width: 8, height: 8)
    }
}
