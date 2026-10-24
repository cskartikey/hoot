//
//  PetPointingFrame.swift
//  Hoot
//
//  The "index-card frame + tab" hoot draws around what it's pointing at
//  (design: wait what Pointing.dc.html → 1b, spec POINTING.md). A 2pt pixel
//  frame with 1-pixel notched corners, a faint accent fill, a 2pt offset
//  "card depth" edge on the bottom and right, and the label in a tab that
//  grows out of the top edge. No radius, no blur, no shadow.
//

import SwiftUI

// MARK: - Walkthrough additions (WALKTHROUGH.md)

/// `accent` while pointing or walking through; `accent2` (= completed) for done.
enum PetPointingFrameTone: Equatable {
    case accent
    case accent2
}

/// What the tab says. A walkthrough tab is "badge · label" with, in some
/// states, three stepping dots after the word or a pixel check before it.
struct PetPointingTabContent: Equatable {
    /// "1 of 3", "your turn", "checking", "done", "still this one".
    var badge: String?
    /// The step's label; truncated with "…" when over the cap, the badge never is.
    var label: String?
    /// 0…3 dots lit (nil = no dots).
    var litDotCount: Int?
    /// 0…7 cells of the pixel check drawn (nil = no check).
    var drawnCheckCellCount: Int?

    static func labelOnly(_ label: String) -> PetPointingTabContent {
        PetPointingTabContent(badge: nil, label: label, litDotCount: nil, drawnCheckCellCount: nil)
    }

    var isEmpty: Bool {
        (badge ?? "").isEmpty && (label ?? "").isEmpty && litDotCount == nil && drawnCheckCellCount == nil
    }

    /// Width ≈ chars × 6.3 + 14 (padding 7/7), plus the dots / check pieces.
    /// Used for the mirror decision before the tab is laid out.
    func estimatedWidth(maximumWidth: CGFloat) -> CGFloat {
        var glyphCount = 0
        if let badge, !badge.isEmpty { glyphCount += badge.count }
        if let label, !label.isEmpty {
            glyphCount += label.count + (glyphCount > 0 ? 3 : 0)
        }
        var width = CGFloat(glyphCount) * 6.3 + 14
        if litDotCount != nil { width += 4 + 10 }
        if drawnCheckCellCount != nil { width += 14 + 4 }
        return min(width, maximumWidth)
    }
}

struct PetPointingFrameView: View {
    /// Padded, clamped size of the frame (see `paddedFrameSize`).
    let frameSize: CGSize
    let label: String?
    /// 0…1, already stepped (8 steps) by the coordinator: the frame draws
    /// clockwise from the top-left.
    let drawProgress: CGFloat
    /// The tab rises 4pt → 0 as it appears.
    let tabRiseOffset: CGFloat
    let tabOpacity: Double
    /// When the frame is too close to the top of the screen, the tab hangs below.
    let isTabBelowFrame: Bool
    let theme: WaitWhatTheme

    // Walkthrough-only knobs; the defaults reproduce the plain pointing frame.
    var tone: PetPointingFrameTone = .accent
    /// 0, 0.5 or 1 of the normal fill alpha (lift / land steps, waiting).
    var fillLevel: CGFloat = 1
    var depthLevel: CGFloat = 1
    /// The peek shutter: one step of a brighter fill.
    var isFillFlashing = false
    /// When set, replaces `label` as the tab's content.
    var tabContent: PetPointingTabContent? = nil
    /// Right edge at frame.w − 8, overhanging left (when it would leave the screen on the right).
    var isTabMirroredLeft = false
    /// Walkthrough cap: max(frame.w − 16, 220) instead of frame.w − 16.
    var tabMaximumWidthOverride: CGFloat? = nil

    static let fallbackElementSize = CGSize(width: 64, height: 40)
    static let paddingAroundElement: CGFloat = 4
    static let minimumFrameSize = CGSize(width: 28, height: 24)
    static let edgeThickness: CGFloat = 2
    /// The depth edge sits 2pt past the frame on the bottom and right.
    static let depthEdgeOutset: CGFloat = 4
    static let tabHeight: CGFloat = 18
    static let tabInsetFromFrameLeft: CGFloat = 8
    /// The tab's visible part above the frame (its bottom 2pt overlap the top edge).
    static let tabVisibleHeightAboveFrame: CGFloat = 16
    /// Transparent room around the frame for the tab (above or below) and a
    /// tab that overhangs to the right. `.drawingGroup()` clips to the view's
    /// bounds, so the tab must be inside them or it disappears.
    static let roomForTabAboveAndBelow: CGFloat = 18
    static let roomForTabOverhangOnRight: CGFloat = 220
    /// Only added (and offset back by the caller) when the tab is mirrored left.
    static let roomForTabOverhangOnLeft: CGFloat = 220

    /// The walkthrough tab cap: buttons are usually narrower than their tab.
    static func walkthroughTabMaximumWidth(forFrameWidth frameWidth: CGFloat) -> CGFloat {
        max(frameWidth - tabInsetFromFrameLeft * 2, 220)
    }

    /// Element box + 4pt padding each side, at least 28×24, at most the screen minus 8pt margins.
    static func paddedFrameSize(forElementSize elementSize: CGSize?, screenSize: CGSize) -> CGSize {
        let element = elementSize ?? fallbackElementSize
        let paddedWidth = element.width + paddingAroundElement * 2
        let paddedHeight = element.height + paddingAroundElement * 2
        return CGSize(
            width: min(max(paddedWidth, minimumFrameSize.width), max(screenSize.width - 16, minimumFrameSize.width)).rounded(),
            height: min(max(paddedHeight, minimumFrameSize.height), max(screenSize.height - 16, minimumFrameSize.height)).rounded()
        )
    }

    var body: some View {
        let frameWidth = frameSize.width
        let frameHeight = frameSize.height
        let toneColor = tone == .accent2 ? theme.accent2 : theme.accent
        let depthEdgeColor = toneColor.opacity((theme.isDark ? 0.45 : 0.35) * Double(depthLevel))
        let fillAlpha: Double = isFillFlashing
            ? (theme.isDark ? 0.35 : 0.20)
            : (theme.isDark ? 0.14 : 0.08) * Double(fillLevel)
        let fillColor = toneColor.opacity(fillAlpha)
        let edge = Self.edgeThickness
        let resolvedTabContent: PetPointingTabContent? = tabContent ?? label.map { PetPointingTabContent.labelOnly($0) }
        let tabMaximumWidth = tabMaximumWidthOverride ?? max(frameWidth - Self.tabInsetFromFrameLeft * 2, 40)

        ZStack(alignment: .topLeading) {
            // Card depth: bottom and right, offset 2pt past the frame.
            Group {
                Rectangle()
                    .fill(depthEdgeColor)
                    .frame(width: frameWidth - edge, height: edge)
                    .offset(x: Self.depthEdgeOutset, y: frameHeight + edge)
                Rectangle()
                    .fill(depthEdgeColor)
                    .frame(width: edge, height: frameHeight - edge)
                    .offset(x: frameWidth + edge, y: Self.depthEdgeOutset)
            }
            .opacity(Double(drawProgress))

            Rectangle()
                .fill(fillColor)
                .frame(width: frameWidth - edge * 2, height: frameHeight - edge * 2)
                .offset(x: edge, y: edge)
                .opacity(Double(drawProgress))

            NotchedPixelFrameShape(drawProgress: drawProgress, edgeThickness: edge)
                .fill(toneColor)
                .frame(width: frameWidth, height: frameHeight)

            if let resolvedTabContent, !resolvedTabContent.isEmpty {
                let tabY = (isTabBelowFrame ? frameHeight - edge : -Self.tabVisibleHeightAboveFrame)
                    + (isTabBelowFrame ? -tabRiseOffset : tabRiseOffset)
                let tabView = PetPointingTabView(
                    content: resolvedTabContent,
                    maximumWidth: tabMaximumWidth,
                    isBelowFrame: isTabBelowFrame,
                    tabColor: toneColor,
                    theme: theme
                )
                .opacity(tabOpacity)
                if isTabMirroredLeft {
                    // Right edge at frame.w − 8; the overhang runs left into
                    // the leading room this view adds in that case.
                    tabView
                        .frame(width: Self.roomForTabOverhangOnLeft + frameWidth - Self.tabInsetFromFrameLeft, alignment: .trailing)
                        .offset(x: -Self.roomForTabOverhangOnLeft, y: tabY)
                } else {
                    tabView.offset(x: Self.tabInsetFromFrameLeft, y: tabY)
                }
            }
        }
        .frame(width: frameWidth + Self.depthEdgeOutset, height: frameHeight + Self.depthEdgeOutset, alignment: .topLeading)
        // Make room for the tab inside the drawing group's bounds; callers
        // place this view `roomForTabAboveAndBelow` above the frame's top
        // (and `roomForTabOverhangOnLeft` to the left when mirrored).
        .padding(.top, Self.roomForTabAboveAndBelow)
        .padding(.bottom, Self.roomForTabAboveAndBelow)
        .padding(.trailing, Self.roomForTabOverhangOnRight)
        .padding(.leading, isTabMirroredLeft ? Self.roomForTabOverhangOnLeft : 0)
        // Keeps the 2pt pixels crisp.
        .drawingGroup()
    }
}

/// The four 2pt edges with the 2×2 corners left empty, revealed clockwise
/// (top, right, bottom, left — each edge in two halves) by `drawProgress`.
private struct NotchedPixelFrameShape: Shape {
    var drawProgress: CGFloat
    let edgeThickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let edge = edgeThickness
        let width = rect.width
        let height = rect.height
        let horizontalLength = width - edge * 2
        let verticalLength = height - edge * 2
        let halfHorizontal = horizontalLength / 2
        let halfVertical = verticalLength / 2

        // The eight half-edges in clockwise drawing order.
        let halfEdgesInDrawOrder: [CGRect] = [
            CGRect(x: edge, y: 0, width: halfHorizontal, height: edge),                                  // top, left half
            CGRect(x: edge + halfHorizontal, y: 0, width: horizontalLength - halfHorizontal, height: edge), // top, right half
            CGRect(x: width - edge, y: edge, width: edge, height: halfVertical),                          // right, top half
            CGRect(x: width - edge, y: edge + halfVertical, width: edge, height: verticalLength - halfVertical), // right, bottom half
            CGRect(x: edge + halfHorizontal, y: height - edge, width: horizontalLength - halfHorizontal, height: edge), // bottom, right half
            CGRect(x: edge, y: height - edge, width: halfHorizontal, height: edge),                       // bottom, left half
            CGRect(x: 0, y: edge + halfVertical, width: edge, height: verticalLength - halfVertical),     // left, bottom half
            CGRect(x: 0, y: edge, width: edge, height: halfVertical)                                      // left, top half
        ]

        let visibleHalfEdgeCount = Int((min(max(drawProgress, 0), 1) * 8).rounded())
        var framePath = Path()
        for halfEdge in halfEdgesInDrawOrder.prefix(visibleHalfEdgeCount) {
            framePath.addRect(halfEdge)
        }
        return framePath
    }
}

/// The label tab: tone color, JetBrains Mono 10.5 semibold, on-accent text,
/// with 2×2 notches on the outer corners only (the other side merges into
/// the frame). Walkthrough tabs add a badge, stepping dots or a pixel check.
private struct PetPointingTabView: View {
    let content: PetPointingTabContent
    let maximumWidth: CGFloat
    let isBelowFrame: Bool
    let tabColor: Color
    let theme: WaitWhatTheme

    /// JetBrains Mono is monospaced (~0.6em per glyph), so the tab can be
    /// truncated to fit without measuring text.
    private static let glyphWidth: CGFloat = 10.5 * 0.6

    var body: some View {
        HStack(spacing: 0) {
            if let drawnCheckCellCount = content.drawnCheckCellCount {
                PetPointingPixelCheckView(drawnCellCount: drawnCheckCellCount, cellColor: theme.onAccent)
                    .padding(.trailing, 4)
            }
            Text(tabText)
                .font(.jetBrainsMono(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(theme.onAccent)
                .lineLimit(1)
                .fixedSize()
            if let litDotCount = content.litDotCount {
                PetPointingTabDotsView(litDotCount: litDotCount, dotColor: theme.onAccent)
                    .padding(.leading, 4)
                    // Bottom-aligned with the text's baseline area.
                    .offset(y: 2)
            }
        }
        .padding(.horizontal, 7)
        .padding(isBelowFrame ? .top : .bottom, 2)
        .frame(height: PetPointingFrameView.tabHeight)
        .background(TabNotchedShape(notchesOnTop: !isBelowFrame).fill(tabColor))
    }

    /// "badge · label", lowercase; only the label's tail is truncated to fit,
    /// the badge never is.
    private var tabText: String {
        let badge = (content.badge ?? "").lowercased()
        let label = (content.label ?? "").lowercased()
        var widthTakenByExtras: CGFloat = 14
        if content.litDotCount != nil { widthTakenByExtras += 14 }
        if content.drawnCheckCellCount != nil { widthTakenByExtras += 18 }
        let availableGlyphCount = Int((maximumWidth - widthTakenByExtras) / Self.glyphWidth)
        guard !label.isEmpty else { return badge }
        guard !badge.isEmpty else { return truncated(label, toGlyphCount: max(availableGlyphCount, 4)) }
        let separator = " · "
        let glyphsLeftForLabel = availableGlyphCount - badge.count - separator.count
        guard glyphsLeftForLabel >= 2 else { return badge }
        return badge + separator + truncated(label, toGlyphCount: glyphsLeftForLabel)
    }

    private func truncated(_ text: String, toGlyphCount maximumGlyphCount: Int) -> String {
        guard text.count > maximumGlyphCount else { return text }
        return String(text.prefix(max(maximumGlyphCount - 1, 1))) + "…"
    }
}

/// Three 2×2 squares, 2pt apart: lit = onAccent, unlit = onAccent @ 0.35.
private struct PetPointingTabDotsView: View {
    let litDotCount: Int
    let dotColor: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Rectangle()
                    .fill(dotColor.opacity(dotIndex < litDotCount ? 1 : 0.35))
                    .frame(width: 2, height: 2)
            }
        }
        .frame(width: 10, height: 2)
    }
}

/// 7 cells of 2×2 on a 14×10 box, drawn in order so it can appear in steps.
private struct PetPointingPixelCheckView: View {
    let drawnCellCount: Int
    let cellColor: Color

    private static let cellColumnsAndRows: [(column: Int, row: Int)] = [(0, 2), (1, 3), (2, 4), (3, 3), (4, 2), (5, 1), (6, 0)]

    var body: some View {
        Canvas { graphicsContext, _ in
            for cell in Self.cellColumnsAndRows.prefix(max(drawnCellCount, 0)) {
                graphicsContext.fill(
                    Path(CGRect(x: CGFloat(cell.column) * 2, y: CGFloat(cell.row) * 2, width: 2, height: 2)),
                    with: .color(cellColor)
                )
            }
        }
        .frame(width: 14, height: 10)
    }
}

private struct TabNotchedShape: Shape {
    let notchesOnTop: Bool

    func path(in rect: CGRect) -> Path {
        let notch: CGFloat = 2
        var tabPath = Path()
        if notchesOnTop {
            tabPath.addRect(CGRect(x: notch, y: 0, width: rect.width - notch * 2, height: notch))
            tabPath.addRect(CGRect(x: 0, y: notch, width: rect.width, height: rect.height - notch))
        } else {
            tabPath.addRect(CGRect(x: 0, y: 0, width: rect.width, height: rect.height - notch))
            tabPath.addRect(CGRect(x: notch, y: rect.height - notch, width: rect.width - notch * 2, height: notch))
        }
        return tabPath
    }
}
