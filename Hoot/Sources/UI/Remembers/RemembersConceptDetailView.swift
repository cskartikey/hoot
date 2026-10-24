//
//  RemembersConceptDetailView.swift
//  Hoot
//
//  One concept in the remembers window: back link, title + ×count, the
//  ladder card (big ladder with the pet on the current step, last check,
//  next review), every past question (▶ replay video in the explainer
//  panel, or read the saved answer inline), and a sticky bottom bar with
//  the native "quiz me now" default button.
//

import SwiftUI

struct RemembersConceptDetailView: View {
    let concept: String
    @ObservedObject var model: RemembersWindowModel
    @ObservedObject var hootController: HootController
    @ObservedObject var memoryStore: MemoryStore
    let theme: WaitWhatTheme
    let petName: String

    @State private var isBackHovered = false

    var body: some View {
        let conceptReview = memoryStore.conceptReview(forConcept: concept)
        let conceptEntries = memoryStore.entries(forConcept: concept)
        let isQuizRunning = model.isQuizRunning(forConcept: concept, hootController: hootController)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backLink
                    if let conceptReview {
                        titleBlock(conceptReview: conceptReview, conceptEntries: conceptEntries)
                        ladderCard(conceptReview: conceptReview)
                            .padding(.top, 30)
                    }
                    Text("past questions")
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(theme.faint)
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    pastQuestions(conceptEntries)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(theme.foreground(opacity: 0.08)).frame(height: 0.5)
            quizBar(isQuizRunning: isQuizRunning)
        }
        .onChange(of: isQuizRunning) { _, isStillRunning in
            if !isStillRunning, model.quizConcept == concept { model.quizConcept = nil }
        }
    }

    // MARK: Back + title

    private var backLink: some View {
        let isSearching = !model.trimmedSearchText.isEmpty
        return Button(action: model.goBackToList) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text(isSearching ? "results for “\(model.trimmedSearchText)”" : "all ideas")
                    .font(.jetBrainsMono(12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isBackHovered ? theme.ink : theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBackHovered = $0 }
        .pointerCursor()
        .padding(.leading, -4)
        .keyboardShortcut("[", modifiers: .command)
        .help("back (⌘[)")
    }

    private func titleBlock(conceptReview: ConceptReview, conceptEntries: [MemoryEntry]) -> some View {
        let timesAsked = max(conceptReview.timesAsked, 1)
        let firstAskedAt = conceptEntries.map(\.askedAt).min() ?? conceptReview.lastAskedAt
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(conceptReview.concept)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.44)
                    .foregroundColor(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("×\(timesAsked)")
                    .font(.jetBrainsMono(12, weight: .medium))
                    .foregroundColor(theme.muted)
            }
            Text("asked \(RemembersWindowModel.pluralized(timesAsked, "time")) · since \(RemembersWindowModel.shortDateText(firstAskedAt))")
                .font(.jetBrainsMono(11))
                .foregroundColor(theme.muted)
        }
        .padding(.top, 12)
    }

    // MARK: Ladder card

    private func ladderCard(conceptReview: ConceptReview) -> some View {
        let isDue = RemembersWindowModel.isDue(conceptReview)
        let isLearned = conceptReview.nextReviewAt == nil
        let displayedStage = RemembersWindowModel.displayedLadderStage(for: conceptReview)
        let petState: PetAnimationState = isLearned ? .hello : (isDue ? .thinking : .idle)

        var lastCheckText = RemembersWindowModel.resultText(for: conceptReview.lastReviewResult)
        if conceptReview.lastReviewResult != nil, let lastReviewedAt = conceptReview.lastReviewedAt {
            lastCheckText += " · \(RemembersWindowModel.shortDateText(lastReviewedAt))"
        }

        return HStack(alignment: .bottom, spacing: 16) {
            RemembersBigReviewLadder(displayedStage: displayedStage, petState: petState, theme: theme)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 12) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("last check")
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(theme.faint)
                    HStack(spacing: 6) {
                        RemembersResultGlyph(reviewResult: conceptReview.lastReviewResult, theme: theme)
                        Text(lastCheckText)
                            .font(.system(size: 13))
                            .foregroundColor(theme.ink)
                            .lineLimit(1)
                    }
                }
                VStack(alignment: .trailing, spacing: 4) {
                    Text("next review")
                        .font(.jetBrainsMono(10.5, weight: .medium))
                        .foregroundColor(theme.faint)
                    Text(RemembersWindowModel.detailNextReviewText(for: conceptReview))
                        .font(.system(size: 13, weight: isDue ? .semibold : .regular))
                        .foregroundColor(theme.ink)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.top, 14)
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .remembersIndexCard(isDue: isDue, theme: theme)
    }

    // MARK: Past questions

    private func pastQuestions(_ conceptEntries: [MemoryEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(conceptEntries.enumerated()), id: \.element.id) { entryIndex, memoryEntry in
                if entryIndex > 0 {
                    Rectangle().fill(theme.foreground(opacity: 0.08)).frame(height: 0.5)
                }
                pastQuestionRow(memoryEntry)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.foreground(opacity: 0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pastQuestionRow(_ memoryEntry: MemoryEntry) -> some View {
        let isAnswerExpanded = model.expandedAnswerEntryId == memoryEntry.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(memoryEntry.question)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundColor(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Image(systemName: RemembersWindowModel.sourceSymbolName(for: memoryEntry))
                            .font(.system(size: 11))
                            .foregroundColor(theme.faint)
                        Text(RemembersWindowModel.sourceTitleText(for: memoryEntry))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let timestampText = RemembersWindowModel.youTubeTimestampText(memoryEntry.youTubeTimeSeconds) {
                            Text("· \(timestampText)")
                                .foregroundColor(theme.ink2)
                                .fixedSize()
                        }
                        Text("· \(RemembersWindowModel.shortDateText(memoryEntry.askedAt))")
                            .foregroundColor(theme.faint)
                            .fixedSize()
                    }
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                replayOrReadButton(memoryEntry, isAnswerExpanded: isAnswerExpanded)
            }
            if isAnswerExpanded {
                savedAnswerBox(memoryEntry)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    /// Small bordered native button: "replay video" (▶ in accent2, "playing"
    /// with a waveform while it plays) or "read answer" / "hide answer".
    private func replayOrReadButton(_ memoryEntry: MemoryEntry, isAnswerExpanded: Bool) -> some View {
        let hasPlayableVideo = memoryEntry.explainerVideoURL.map(RemembersWindowModel.isSavedVideoStillPlayable) ?? false
        let isPlaying = hasPlayableVideo && model.replayingEntryId == memoryEntry.id && hootController.isExplainerVideoPlaying
        let titleText: String
        let symbolName: String
        let symbolColor: Color
        if hasPlayableVideo {
            titleText = isPlaying ? "playing" : "replay video"
            symbolName = isPlaying ? "waveform" : "play.fill"
            symbolColor = theme.accent2
        } else {
            titleText = isAnswerExpanded ? "hide answer" : "read answer"
            symbolName = isAnswerExpanded ? "chevron.up" : "text.alignleft"
            symbolColor = theme.ink2
        }
        return Button {
            model.replayOrReadAnswer(for: memoryEntry)
        } label: {
            Label {
                Text(titleText)
                    .font(.system(size: 12, weight: .medium))
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
            }
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .pointerCursor()
    }

    private func savedAnswerBox(_ memoryEntry: MemoryEntry) -> some View {
        let trimmedSummary = memoryEntry.answerSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(petName) said")
                .font(.jetBrainsMono(10.5, weight: .medium))
                .foregroundColor(theme.faint)
            Text(trimmedSummary.isEmpty ? "i didn't keep the answer to this one." : trimmedSummary)
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundColor(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.foreground(opacity: 0.08), lineWidth: 0.5))
    }

    // MARK: Quiz bar

    private func quizBar(isQuizRunning: Bool) -> some View {
        HStack(spacing: 16) {
            Text(isQuizRunning
                 ? "listening for your answer · hold ⌃⌥ to reply"
                 : "\(petName) asks one quick question out loud. answer with ⌃⌥.")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundColor(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.startQuiz(forConcept: concept)
            } label: {
                HStack(spacing: 6) {
                    if isQuizRunning {
                        Image(systemName: "waveform")
                    }
                    Text(isQuizRunning ? "\(petName) is asking…" : "quiz me now")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(isQuizRunning || memoryStore.conceptReview(forConcept: concept) == nil)
            .opacity(isQuizRunning ? 0.75 : 1)
            .pointerCursor(isEnabled: !isQuizRunning)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}
