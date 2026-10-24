//
//  MenuPanelMemoryViews.swift
//  Hoot
//
//  The memory pieces of the menu bar panel (docs/MEMORY.md §5–7):
//    - the "<pet> remembers" concept chips (wrapping row, top concept in
//      accent2, the rest neutral; tapping one filters the recent list)
//    - the saved answer card a recent row opens when it has no video
//    - the wrapping layout the chips sit in
//  Every color comes from the WaitWhatTheme passed in.
//

import SwiftUI

// MARK: - Wrapping layout

/// Lays its children out left to right and wraps onto a new line when the
/// next one would not fit, like the design's `flex-wrap` chip row.
struct MenuPanelWrappingLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let childFrames = frames(for: subviews, availableWidth: availableWidth)
        let usedWidth = childFrames.map(\.maxX).max() ?? 0
        let usedHeight = childFrames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: usedHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let childFrames = frames(for: subviews, availableWidth: bounds.width)
        for (subview, childFrame) in zip(subviews, childFrames) {
            subview.place(
                at: CGPoint(x: bounds.minX + childFrame.minX, y: bounds.minY + childFrame.minY),
                proposal: ProposedViewSize(childFrame.size)
            )
        }
    }

    private func frames(for subviews: Subviews, availableWidth: CGFloat) -> [CGRect] {
        var childFrames: [CGRect] = []
        var nextOriginX: CGFloat = 0
        var currentLineOriginY: CGFloat = 0
        var currentLineHeight: CGFloat = 0

        for subview in subviews {
            let childSize = subview.sizeThatFits(.unspecified)
            let wouldOverflowLine = nextOriginX > 0 && nextOriginX + childSize.width > availableWidth
            if wouldOverflowLine {
                currentLineOriginY += currentLineHeight + verticalSpacing
                nextOriginX = 0
                currentLineHeight = 0
            }
            childFrames.append(CGRect(origin: CGPoint(x: nextOriginX, y: currentLineOriginY), size: childSize))
            nextOriginX += childSize.width + horizontalSpacing
            currentLineHeight = max(currentLineHeight, childSize.height)
        }
        return childFrames
    }
}

// MARK: - Concept chip

/// One memory chip: JBM 11/500, r6, padding 3/7. The top concept uses
/// `accent2@0.12` / `accent2Ink`; the rest `fg@0.05` / ink. The chip the
/// recent list is filtered by gets a 1pt ring so the filter is visible.
struct MenuPanelMemoryConceptChip: View {
    let conceptReview: ConceptReview
    let isTopConcept: Bool
    let isActiveFilter: Bool
    let theme: WaitWhatTheme
    let onTap: () -> Void

    @State private var isHovered = false

    private var chipTitleText: String {
        conceptReview.timesAsked > 1
            ? "\(conceptReview.concept) ×\(conceptReview.timesAsked)"
            : conceptReview.concept
    }

    var body: some View {
        Button(action: onTap) {
            Text(chipTitleText)
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(isTopConcept ? theme.accent2Ink : theme.ink)
                .lineLimit(1)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(chipBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActiveFilter ? theme.accent2 : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            isHovered = isHovering
        }
        .pointerCursor()
        .help(isActiveFilter ? "show every recent question" : "show only questions about \(conceptReview.concept)")
    }

    private var chipBackgroundColor: Color {
        if isTopConcept {
            return theme.accent2.opacity(isHovered ? 0.18 : 0.12)
        }
        return theme.foreground(opacity: isHovered ? 0.09 : 0.05)
    }
}

// MARK: - Saved answer card

/// What a recent row opens when its question has no video: a small card in
/// the response bubble's style (accent dot + pet name, then the answer) with
/// the question above and the source + time below. Tapping it closes it.
struct MenuPanelSavedAnswerCard: View {
    let memoryEntry: MemoryEntry
    let petName: String
    let theme: WaitWhatTheme
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text(petName)
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(theme.muted)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.faint)
                }

                Text(memoryEntry.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(answerSummaryText)
                    .font(.system(size: 13.5))
                    .foregroundColor(theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metaText)
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.solid.opacity(theme.isDark ? 0.55 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.foreground(opacity: 0.12), lineWidth: 0.5)
            )
            .shadow(color: theme.shadowColor.opacity(0.12), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("close")
    }

    private var answerSummaryText: String {
        let trimmedSummary = memoryEntry.answerSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSummary.isEmpty ? "i didn't keep the answer to this one." : trimmedSummary
    }

    /// "concept · source at 6:52 · 2h"
    private var metaText: String {
        var metaParts: [String] = []
        if !memoryEntry.concept.isEmpty {
            metaParts.append(memoryEntry.concept)
        }
        if let sourceTitle = memoryEntry.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceTitle.isEmpty {
            if let youTubeTimeSeconds = memoryEntry.youTubeTimeSeconds, youTubeTimeSeconds.isFinite, youTubeTimeSeconds >= 0 {
                let wholeSeconds = Int(youTubeTimeSeconds)
                metaParts.append("\(sourceTitle.lowercased()) at \(wholeSeconds / 60):\(String(format: "%02d", wholeSeconds % 60))")
            } else {
                metaParts.append(sourceTitle.lowercased())
            }
        }
        metaParts.append(RecentQuestionsStore.relativeTimeDescription(for: memoryEntry.askedAt))
        return metaParts.joined(separator: " · ")
    }
}
