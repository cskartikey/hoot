//
//  MenuPanelHomeView.swift
//  Hoot
//
//  Screen 2 of the crisp design: the everyday menu bar panel. Pet header
//  ("hoot", "<pet> is ready", ⌃⌥ keycaps), the recent questions, the
//  "<pet> remembers" concept chips, and the settings… / quit rows.
//
//  Recent rows come from MemoryStore (falling back to the older
//  RecentQuestionsStore until the first memory is saved). A row with a
//  saved explainer video reopens it in the explainer panel; one without
//  opens the saved answer as a small card in place of the list. Tapping a
//  chip filters the list to that concept; tapping it again clears it.
//

import AppKit
import SwiftUI

struct MenuPanelHomeView: View {
    @ObservedObject var hootController: HootController
    @ObservedObject private var recentQuestionsStore = RecentQuestionsStore.shared
    @ObservedObject private var memoryStore = MemoryStore.shared
    let theme: WaitWhatTheme
    let petName: String
    /// True for a moment right after onboarding finishes, so the pet waves.
    let isWavingHelloAfterOnboarding: Bool
    let onOpenSettings: () -> Void

    private let maximumRecentQuestionRowCount = 4
    private let maximumMemoryChipCount = 4

    /// The concept chip the recent list is filtered by, if any.
    @State private var selectedConceptFilter: String?
    /// The saved answer shown as a card in place of the recent rows.
    @State private var memoryEntryShownInAnswerCard: MemoryEntry?

    private let memoryAnimation = Animation.easeInOut(duration: 0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuPanelHairline(theme: theme)
            MenuPanelSectionLabel(labelText: recentSectionLabelText, theme: theme)
                .padding(.top, 10)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            if let memoryEntryShownInAnswerCard {
                MenuPanelSavedAnswerCard(
                    memoryEntry: memoryEntryShownInAnswerCard,
                    petName: petName,
                    theme: theme,
                    onClose: {
                        withAnimation(memoryAnimation) { self.memoryEntryShownInAnswerCard = nil }
                    }
                )
                .padding(.horizontal, 2)
                .transition(.opacity)
            } else {
                recentQuestionRows
                    .transition(.opacity)
            }
            memoryChipsSection
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

    /// "recent", or "recent · determinants" while a chip filters the list.
    private var recentSectionLabelText: String {
        guard let activeConceptFilter else { return "recent" }
        return "recent · \(activeConceptFilter)"
    }

    /// The selected chip's concept, but only while that chip still exists
    /// (after "forget everything" the filter quietly drops away).
    private var activeConceptFilter: String? {
        guard let selectedConceptFilter,
              displayedConceptReviews.contains(where: { $0.concept == selectedConceptFilter }) else { return nil }
        return selectedConceptFilter
    }

    private var displayedMemoryEntries: [MemoryEntry] {
        let matchingMemoryEntries: [MemoryEntry]
        if let activeConceptFilter {
            matchingMemoryEntries = memoryStore.entries.filter { $0.concept == activeConceptFilter }
        } else {
            matchingMemoryEntries = memoryStore.entries
        }
        return Array(matchingMemoryEntries.prefix(maximumRecentQuestionRowCount))
    }

    @ViewBuilder
    private var recentQuestionRows: some View {
        if !memoryStore.entries.isEmpty {
            memoryEntryRows
        } else {
            legacyRecentQuestionRows
        }
    }

    private var memoryEntryRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedMemoryEntries.enumerated()), id: \.element.id) { entryIndex, memoryEntry in
                let isMostRecent = entryIndex == 0
                MenuPanelRecentQuestionRow(
                    symbolName: memoryEntry.explainerVideoURL != nil ? "play.circle.fill" : "bubble.left",
                    symbolColor: isMostRecent ? theme.accent : theme.faint,
                    titleText: memoryEntry.question,
                    metaText: metaText(sourceTitle: memoryEntry.sourceTitle, askedDate: memoryEntry.askedAt),
                    isMostRecent: isMostRecent,
                    theme: theme,
                    onSelect: { openSavedMemory(memoryEntry) }
                )
            }
        }
    }

    /// Questions saved before memory existed (or before the first memory is
    /// written). They carry no answer or video address, so they aren't buttons.
    @ViewBuilder
    private var legacyRecentQuestionRows: some View {
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
                        metaText: metaText(sourceTitle: recentQuestion.sourceDescription, askedDate: recentQuestion.askedDate),
                        isMostRecent: isMostRecent,
                        theme: theme
                    )
                }
            }
        }
    }

    private func metaText(sourceTitle: String?, askedDate: Date) -> String {
        let relativeTimeText = RecentQuestionsStore.relativeTimeDescription(for: askedDate)
        guard let sourceTitle = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceTitle.isEmpty else { return relativeTimeText }
        return "\(sourceTitle.lowercased()) · \(relativeTimeText)"
    }

    /// Video → replay it in the explainer panel. No video (or the video file
    /// is gone, or the explainer panel isn't around) → the saved answer card.
    private func openSavedMemory(_ memoryEntry: MemoryEntry) {
        if let explainerVideoURLString = memoryEntry.explainerVideoURL,
           Self.isSavedVideoStillPlayable(explainerVideoURLString),
           let explainerPanelManager = ExplainerPanelManager.shared {
            explainerPanelManager.playSavedVideo(url: explainerVideoURLString, title: memoryEntry.question)
            return
        }
        withAnimation(memoryAnimation) {
            memoryEntryShownInAnswerCard = memoryEntry
        }
    }

    /// Local files are checked on disk; studio URLs (http) are trusted, since
    /// checking them would mean a network round trip on every tap.
    private static func isSavedVideoStillPlayable(_ explainerVideoURLString: String) -> Bool {
        guard let explainerVideoURL = URL(string: explainerVideoURLString) else { return false }
        if explainerVideoURL.isFileURL {
            return FileManager.default.fileExists(atPath: explainerVideoURL.path)
        }
        return true
    }

    // MARK: - "<pet> remembers" chips

    private var displayedConceptReviews: [ConceptReview] {
        memoryStore.topConcepts(limit: maximumMemoryChipCount)
    }

    @ViewBuilder
    private var memoryChipsSection: some View {
        let conceptReviews = displayedConceptReviews
        if !conceptReviews.isEmpty {
            MenuPanelHairline(theme: theme)
                .padding(.top, 6)
            MenuPanelSectionLabel(labelText: "\(petName) remembers", theme: theme)
                .padding(.top, 10)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            MenuPanelWrappingLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(Array(conceptReviews.enumerated()), id: \.element.id) { conceptIndex, conceptReview in
                    MenuPanelMemoryConceptChip(
                        conceptReview: conceptReview,
                        isTopConcept: conceptIndex == 0,
                        isActiveFilter: activeConceptFilter == conceptReview.concept,
                        theme: theme,
                        onTap: {
                            // ⌥-click opens the idea in the remembers window.
                            if NSEvent.modifierFlags.contains(.option) {
                                RemembersWindowController.shared.show(hootController: hootController, focusingConcept: conceptReview.concept)
                            } else {
                                toggleConceptFilter(conceptReview.concept)
                            }
                        }
                    )
                }
                RemembersSeeAllChip(theme: theme) {
                    RemembersWindowController.shared.show(hootController: hootController)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func toggleConceptFilter(_ concept: String) {
        withAnimation(memoryAnimation) {
            memoryEntryShownInAnswerCard = nil
            selectedConceptFilter = activeConceptFilter == concept ? nil : concept
        }
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
