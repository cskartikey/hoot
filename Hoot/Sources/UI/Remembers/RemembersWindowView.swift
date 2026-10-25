//
//  RemembersWindowView.swift
//  Hoot
//
//  Root of the "what hoot remembers" window and its list screen: header
//  (pet, title, counts, due indicator), the native search field, the
//  two-column grid of index cards, live search results ("questions"), and
//  the two empty states. The concept detail is RemembersConceptDetailView.
//

import SwiftUI

struct RemembersWindowView: View {
    @ObservedObject var model: RemembersWindowModel
    @ObservedObject var hootController: HootController
    @ObservedObject private var memoryStore = MemoryStore.shared
    @ObservedObject private var themeStore = WaitWhatThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionOn

    static let windowSize = CGSize(width: 520, height: 600)
    /// The transparent titlebar band the traffic lights sit in.
    static let titlebarBandHeight: CGFloat = 36

    private var theme: WaitWhatTheme { themeStore.theme }

    var body: some View {
        ZStack {
            switch model.route {
            case .list:
                RemembersListScreen(model: model, memoryStore: memoryStore, theme: theme, petName: themeStore.mascot.displayName)
                    .transition(screenTransition)
            case .conceptDetail(let concept):
                RemembersConceptDetailView(
                    concept: concept,
                    model: model,
                    hootController: hootController,
                    memoryStore: memoryStore,
                    theme: theme,
                    petName: themeStore.mascot.displayName
                )
                .id(concept)
                .transition(screenTransition)
            }
        }
        .animation(isReduceMotionOn ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25), value: model.route)
        .padding(.top, Self.titlebarBandHeight)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
        .clipped()
        .background(
            ZStack {
                RemembersWindowMaterial()
                theme.glassTint
            }
        )
        .foregroundColor(theme.ink)
        .tint(theme.accent)
        .ignoresSafeArea()
        .onChange(of: memoryStore.conceptReviews) { _, newConceptReviews in
            // Forgotten from settings while open: back to the list.
            if case .conceptDetail(let concept) = model.route,
               !newConceptReviews.contains(where: { $0.concept == concept }) {
                model.goBackToList()
            }
        }
        .onChange(of: hootController.isExplainerPanelOpen) { _, isPlaying in
            if !isPlaying { model.clearReplayingEntry() }
        }
    }

    /// Push (forward slides in from the right, back from the left), or a
    /// crossfade with Reduce Motion.
    private var screenTransition: AnyTransition {
        if isReduceMotionOn { return .opacity }
        return model.isNavigatingForward
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }
}

// MARK: - List screen

private struct RemembersListScreen: View {
    @ObservedObject var model: RemembersWindowModel
    @ObservedObject var memoryStore: MemoryStore
    let theme: WaitWhatTheme
    let petName: String

    var body: some View {
        let conceptMatches = model.conceptMatches(in: memoryStore)
        let questionMatches = model.questionMatches(in: memoryStore)
        let isMemoryEmpty = memoryStore.conceptReviews.isEmpty
        let isShowingNoResults = !isMemoryEmpty && !model.trimmedSearchText.isEmpty
            && conceptMatches.isEmpty && questionMatches.isEmpty

        VStack(spacing: 0) {
            header(isMemoryEmpty: isMemoryEmpty, isShowingNoResults: isShowingNoResults)

            RemembersNativeSearchField(
                text: $model.searchText,
                placeholderText: "search what you've asked…",
                isEnabled: !isMemoryEmpty,
                focusRequestCount: model.searchFocusRequestCount
            )
            .opacity(isMemoryEmpty ? 0.5 : 1)
            .padding(.horizontal, 20)

            ScrollView {
                Group {
                    if isMemoryEmpty {
                        nothingRememberedState
                    } else if isShowingNoResults {
                        noSearchResultsState
                    } else {
                        conceptGridAndQuestions(conceptMatches: conceptMatches, questionMatches: questionMatches)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Header

    private func header(isMemoryEmpty: Bool, isShowingNoResults: Bool) -> some View {
        let dueCount = memoryStore.conceptReviews.filter { RemembersWindowModel.isDue($0) }.count
        let questionCount = memoryStore.conceptReviews.reduce(0) { $0 + max($1.timesAsked, 1) }
        let headerMetaText = isMemoryEmpty
            ? "nothing yet"
            : "\(RemembersWindowModel.pluralized(memoryStore.conceptReviews.count, "idea")) · \(RemembersWindowModel.pluralized(questionCount, "question"))"

        return HStack(spacing: 12) {
            PetSpriteView(state: isShowingNoResults ? .thinking : .idle, scale: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("what \(petName) remembers")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.17)
                    .foregroundColor(theme.ink)
                Text(headerMetaText)
                    .font(.jetBrainsMono(11, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            Spacer(minLength: 0)
            if dueCount > 0 {
                HStack(spacing: 7) {
                    RemembersDueIndicatorSquare(theme: theme)
                    Text("\(dueCount) due now")
                        .font(.jetBrainsMono(11, weight: .semibold))
                        .foregroundColor(theme.ink)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: Grid + questions

    private func conceptGridAndQuestions(
        conceptMatches: [RemembersConceptSearchMatch],
        questionMatches: [RemembersQuestionSearchMatch]
    ) -> some View {
        let isSearching = !model.trimmedSearchText.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isSearching
                     ? "\(RemembersWindowModel.pluralized(conceptMatches.count, "idea")) · \(RemembersWindowModel.pluralized(questionMatches.count, "question"))"
                     : "all ideas")
                Spacer(minLength: 12)
                Text(isSearching ? "“\(model.trimmedSearchText)”" : "due first")
                    .lineLimit(1)
            }
            .font(.jetBrainsMono(10.5, weight: .medium))
            .foregroundColor(theme.faint)
            .padding(.bottom, 20)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(conceptMatches) { conceptMatch in
                    RemembersConceptCard(
                        conceptReview: conceptMatch.conceptReview,
                        matchedNameRange: conceptMatch.matchedNameRange,
                        theme: theme,
                        onOpen: { model.openConceptDetail(conceptMatch.conceptReview.concept) }
                    )
                }
            }

            if !questionMatches.isEmpty {
                Text("questions")
                    .font(.jetBrainsMono(10.5, weight: .medium))
                    .foregroundColor(theme.faint)
                    .padding(.top, 26)
                    .padding(.bottom, 8)
                VStack(spacing: 0) {
                    ForEach(Array(questionMatches.enumerated()), id: \.element.id) { matchIndex, questionMatch in
                        if matchIndex > 0 {
                            Rectangle().fill(theme.foreground(opacity: 0.08)).frame(height: 0.5)
                        }
                        RemembersSearchQuestionRow(
                            questionMatch: questionMatch,
                            theme: theme,
                            onOpen: { model.openConceptDetail(questionMatch.memoryEntry.concept) }
                        )
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.foreground(opacity: 0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Empty states

    private var nothingRememberedState: some View {
        VStack(spacing: 22) {
            RemembersGhostCard(theme: theme)
            VStack(spacing: 8) {
                Text("\(petName) doesn't remember anything yet")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundColor(theme.ink)
                RemembersText.sentenceWithKeycap(
                    before: "hold ",
                    after: " and ask about whatever's confusing you. i'll keep the idea here and check back in a day, then three, then a week, so it sticks.",
                    theme: theme
                )
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
    }

    private var noSearchResultsState: some View {
        VStack(spacing: 10) {
            Text("nothing about “\(model.trimmedSearchText)” yet")
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundColor(theme.ink)
                .multilineTextAlignment(.center)
            RemembersText.sentenceWithKeycap(
                before: "search looks through idea names and every question you've asked \(petName). next time it's on screen, hold ",
                after: " and ask.",
                theme: theme
            )
            .font(.system(size: 13))
            .lineSpacing(4)
            .foregroundColor(theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            Button("clear search") { model.searchText = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 6)
        }
        .padding(.top, 72 - 16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Concept card

private struct RemembersConceptCard: View {
    let conceptReview: ConceptReview
    let matchedNameRange: Range<String.Index>?
    let theme: WaitWhatTheme
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isDue = RemembersWindowModel.isDue(conceptReview)
        let isLearned = conceptReview.nextReviewAt == nil

        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(RemembersText.highlighted(conceptReview.concept, range: matchedNameRange, theme: theme))
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.07)
                        .foregroundColor(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("×\(max(conceptReview.timesAsked, 1))")
                        .font(.jetBrainsMono(11, weight: .medium))
                        .foregroundColor(theme.muted)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    RemembersSmallReviewLadder(
                        displayedStage: RemembersWindowModel.displayedLadderStage(for: conceptReview),
                        theme: theme
                    )
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 6) {
                            RemembersResultGlyph(reviewResult: conceptReview.lastReviewResult, theme: theme)
                            Text(RemembersWindowModel.resultText(for: conceptReview.lastReviewResult))
                                .font(.system(size: 12))
                                .foregroundColor(theme.ink2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(RemembersWindowModel.cardNextReviewText(for: conceptReview))
                            .font(.jetBrainsMono(11, weight: isDue ? .semibold : .regular))
                            .foregroundColor(isDue ? theme.ink : theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .layoutPriority(1)
                }
            }
            .padding(.top, 13)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .remembersIndexCard(isDue: isDue, theme: theme)
            .offset(x: isHovered ? -1 : 0, y: isHovered ? -1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityLabel("\(conceptReview.concept), asked \(conceptReview.timesAsked) times, \(isLearned ? "learned" : RemembersWindowModel.cardNextReviewText(for: conceptReview))")
    }
}

// MARK: - Search question row

private struct RemembersSearchQuestionRow: View {
    let questionMatch: RemembersQuestionSearchMatch
    let theme: WaitWhatTheme
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        let memoryEntry = questionMatch.memoryEntry
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RemembersText.highlighted(memoryEntry.question, range: questionMatch.matchedQuestionRange, theme: theme))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundColor(theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(memoryEntry.concept)
                            .foregroundColor(theme.ink)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.foreground(opacity: 0.06)))
                            .fixedSize()
                        Text(sourceAndTimestampText(memoryEntry))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("· \(RemembersWindowModel.shortDateText(memoryEntry.askedAt))")
                            .foregroundColor(theme.faint)
                            .fixedSize()
                    }
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.faint)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(isHovered ? theme.foreground(opacity: 0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }

    private func sourceAndTimestampText(_ memoryEntry: MemoryEntry) -> String {
        let sourceText = RemembersWindowModel.sourceTitleText(for: memoryEntry)
        guard let timestampText = RemembersWindowModel.youTubeTimestampText(memoryEntry.youTubeTimeSeconds) else { return sourceText }
        return "\(sourceText) · \(timestampText)"
    }
}
