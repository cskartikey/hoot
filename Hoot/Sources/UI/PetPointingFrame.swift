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
        let depthEdgeColor = theme.accent.opacity(theme.isDark ? 0.45 : 0.35)
        let fillColor = theme.accent.opacity(theme.isDark ? 0.14 : 0.08)
        let edge = Self.edgeThickness

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
                .fill(theme.accent)
                .frame(width: frameWidth, height: frameHeight)

            if let label {
                PetPointingTabView(
                    labelText: label,
                    maximumWidth: max(frameWidth - Self.tabInsetFromFrameLeft * 2, 40),
                    isBelowFrame: isTabBelowFrame,
                    theme: theme
                )
                .offset(
                    x: Self.tabInsetFromFrameLeft,
                    y: (isTabBelowFrame ? frameHeight - edge : -Self.tabVisibleHeightAboveFrame)
                        + (isTabBelowFrame ? -tabRiseOffset : tabRiseOffset)
                )
                .opacity(tabOpacity)
            }
        }
        .frame(width: frameWidth + Self.depthEdgeOutset, height: frameHeight + Self.depthEdgeOutset, alignment: .topLeading)
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

/// The label tab: accent, JetBrains Mono 10.5 semibold, on-accent text, with
/// 2×2 notches on the outer corners only (the other side merges into the frame).
private struct PetPointingTabView: View {
    let labelText: String
    let maximumWidth: CGFloat
    let isBelowFrame: Bool
    let theme: WaitWhatTheme

    var body: some View {
        Text(truncatedLabelText)
            .font(.jetBrainsMono(10.5, weight: .semibold))
            .foregroundColor(theme.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(isBelowFrame ? .top : .bottom, 2)
            .frame(height: PetPointingFrameView.tabHeight)
            .background(TabNotchedShape(notchesOnTop: !isBelowFrame).fill(theme.accent))
    }

    /// JetBrains Mono is monospaced (~0.6em per glyph), so the tab can be
    /// truncated to fit the frame without measuring text.
    private var truncatedLabelText: String {
        let lowercasedLabel = labelText.lowercased()
        let glyphWidth: CGFloat = 10.5 * 0.6
        let maximumGlyphCount = max(Int((maximumWidth - 14) / glyphWidth), 4)
        guard lowercasedLabel.count > maximumGlyphCount else { return lowercasedLabel }
        return String(lowercasedLabel.prefix(maximumGlyphCount - 1)) + "…"
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
