//
//  MenuPanelHomeView.swift
//  Hoot
//
//  Screen 2 of the crisp design: the everyday menu bar panel. Pet header
//  ("hoot", "<pet> is ready", ⌃⌥ keycaps), the recent questions, and the
//  settings… / quit rows.
//

import AppKit
import SwiftUI

struct MenuPanelHomeView: View {
    @ObservedObject var hootController: HootController
    @ObservedObject private var recentQuestionsStore = RecentQuestionsStore.shared
    let theme: WaitWhatTheme
    let petName: String
    /// True for a moment right after onboarding finishes, so the pet waves.
    let isWavingHelloAfterOnboarding: Bool
    let onOpenSettings: () -> Void

    private let maximumRecentQuestionRowCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuPanelHairline(theme: theme)
            MenuPanelSectionLabel(labelText: "recent", theme: theme)
                .padding(.top, 10)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            recentQuestionRows
            MenuPanelHairline(theme: theme)
                .padding(.top, 6)
            menuRows
                .padding(.vertical, 4)
        }
        .padding(6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PetSpriteView(state: headerPetAnimationState, scale: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("hoot")
                    .font(.jetBrainsMono(13, weight: .semibold))
                    .foregroundColor(theme.ink)
                Text(headerStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                WaitWhatKeycap(symbol: "⌃", theme: theme)
                WaitWhatKeycap(symbol: "⌥", theme: theme)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var headerPetAnimationState: PetAnimationState {
        if isWavingHelloAfterOnboarding {
            return .hello
        }
        switch hootController.voiceState {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return hootController.isAnswerPipelineRunning ? .thinking : .idle
        case .responding: return .talking
        }
    }

    private var headerStatusText: String {
        switch hootController.voiceState {
        case .idle: return "\(petName) is ready"
        case .listening: return "\(petName) is listening"
        case .processing: return hootController.isAnswerPipelineRunning ? "\(petName) is thinking" : "\(petName) is ready"
        case .responding: return "\(petName) is talking"
        }
    }

    // MARK: - Recent questions

    @ViewBuilder
    private var recentQuestionRows: some View {
        let displayedRecentQuestions = Array(recentQuestionsStore.recentQuestions.prefix(maximumRecentQuestionRowCount))

        if displayedRecentQuestions.isEmpty {
            MenuPanelRecentQuestionRow(
                symbolName: "bubble.left",
                symbolColor: theme.faint,
                titleText: "ask your first question with ⌃⌥",
                metaText: "nothing here yet",
                isMostRecent: false,
                theme: theme
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(displayedRecentQuestions.enumerated()), id: \.element.id) { questionIndex, recentQuestion in
                    let isMostRecent = questionIndex == 0
                    MenuPanelRecentQuestionRow(
                        symbolName: recentQuestion.hadExplainerVideo ? "play.circle.fill" : "bubble.left",
                        symbolColor: isMostRecent ? theme.accent : theme.faint,
                        titleText: recentQuestion.questionText,
                        metaText: metaText(for: recentQuestion),
                        isMostRecent: isMostRecent,
                        theme: theme
                    )
                }
            }
        }
    }

    private func metaText(for recentQuestion: RecentQuestion) -> String {
        let relativeTimeText = RecentQuestionsStore.relativeTimeDescription(for: recentQuestion.askedDate)
        guard let sourceDescription = recentQuestion.sourceDescription else { return relativeTimeText }
        return "\(sourceDescription) · \(relativeTimeText)"
    }

    // MARK: - Menu rows

    private var menuRows: some View {
        VStack(spacing: 0) {
            MenuPanelHoverButton(theme: theme, action: onOpenSettings) {
                menuRowContent(titleText: "settings…", shortcutText: "⌘,")
            }
            .keyboardShortcut(",", modifiers: .command)

            MenuPanelHoverButton(theme: theme, action: { NSApp.terminate(nil) }) {
                menuRowContent(titleText: "quit", shortcutText: "⌘Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func menuRowContent(titleText: String, shortcutText: String) -> some View {
        HStack {
            Text(titleText)
                .font(.system(size: 13))
                .foregroundColor(theme.ink)
            Spacer()
            Text(shortcutText)
                .font(.jetBrainsMono(11))
                .foregroundColor(theme.faint)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
