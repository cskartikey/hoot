//
//  CornerNudgeBubbleView.swift
//  Hoot
//
//  The corner nudge bubble from design 4a: 220pt of glass (radius 14,
//  padding 10/12), a line of SF 12.5 text with the key phrase in
//  accent2Ink, and two JetBrains Mono 11 pills: the primary in the accent,
//  the secondary neutral. Fades in while rising 4pt.
//

import SwiftUI

struct CornerNudgeBubbleView: View {
    let nudge: HootNudge

    @ObservedObject private var themeStore = WaitWhatThemeStore.shared
    @State private var hasAppeared = false

    static let bubbleWidth: CGFloat = 220

    var body: some View {
        let theme = themeStore.theme
        let bubbleShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            Text(messageWithEmphasis(theme: theme))
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    NudgeCenter.shared.performPrimaryActionOfCurrentNudge()
                } label: {
                    Text(nudge.primaryButtonTitle)
                        .font(.jetBrainsMono(11, weight: .semibold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule(style: .continuous).fill(theme.accent))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    NudgeCenter.shared.performSecondaryActionOfCurrentNudge()
                } label: {
                    Text(nudge.secondaryButtonTitle)
                        .font(.jetBrainsMono(11, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule(style: .continuous).fill(theme.foreground(opacity: theme.isDark ? 0.10 : 0.05)))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: Self.bubbleWidth, alignment: .leading)
        .background(
            ZStack {
                bubbleShape.fill(.ultraThinMaterial)
                bubbleShape.fill(theme.glassTint)
            }
        )
        .overlay(bubbleShape.strokeBorder(theme.foreground(opacity: 0.12), lineWidth: 0.5))
        .clipShape(bubbleShape)
        // The mock's 0 14px 28px -12px shadow, approximated.
        .shadow(color: theme.shadowColor.opacity(theme.panelShadowOpacity * 1.1), radius: 9, x: 0, y: 8)
        .onHover { isHovering in
            NudgeCenter.shared.isPointerOverCurrentNudge = isHovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 4)
        .padding(CornerNudgePresenter.shadowMarginAroundBubble)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { hasAppeared = true }
        }
    }

    /// The message with `emphasizedPhrase` in accent2Ink: weight 500 for a
    /// concept (as in "same idea as determinants"), 600 for a title.
    private func messageWithEmphasis(theme: WaitWhatTheme) -> AttributedString {
        var attributedMessage = AttributedString(nudge.message)
        guard let emphasizedPhrase = nudge.emphasizedPhrase, !emphasizedPhrase.isEmpty,
              let emphasizedRange = attributedMessage.range(of: emphasizedPhrase) else {
            return attributedMessage
        }
        let emphasisWeight: Font.Weight = nudge.kind == .videoReadyWhileAway ? .semibold : .medium
        attributedMessage[emphasizedRange].foregroundColor = theme.accent2Ink
        attributedMessage[emphasizedRange].font = .system(size: 12.5, weight: emphasisWeight)
        return attributedMessage
    }
}
