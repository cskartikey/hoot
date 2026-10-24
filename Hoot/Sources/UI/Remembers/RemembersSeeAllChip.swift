//
//  RemembersSeeAllChip.swift
//  Hoot
//
//  The trailing "see all…" chip in the menu panel's "<pet> remembers" row
//  (JBM 11/500, fg@0.05, r6, like the concept chips). Opens or focuses the
//  remembers window.
//

import SwiftUI

struct RemembersSeeAllChip: View {
    let theme: WaitWhatTheme
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text("see all…")
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.foreground(opacity: isHovered ? 0.09 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .help("everything \(theme.mascot.displayName) remembers (⌥-click an idea to open it there)")
    }
}
