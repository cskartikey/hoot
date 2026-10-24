//
//  MenuPanelSettingsView.swift
//  Hoot
//
//  Screen 3 of the crisp design, pushed from home: model, voice + speed,
//  buddy (+ "always visible"), appearance, memory (count, nudges, review
//  demo mode, forget everything), and the permissions summary.
//  Picking a buddy or an appearance re-themes the whole app at once,
//  because everything reads WaitWhatThemeStore.
//

import SwiftUI

struct MenuPanelSettingsView: View {
    @ObservedObject var hootController: HootController
    @ObservedObject var permissionCenter: PermissionCenter
    @ObservedObject private var themeStore = WaitWhatThemeStore.shared
    @ObservedObject private var voiceSettingsStore = WaitWhatVoiceSettingsStore.shared
    @ObservedObject private var memoryStore = MemoryStore.shared
    @ObservedObject private var nudgeCenter = NudgeCenter.shared
    /// Read by the spaced-review ladder: minutes instead of days, so a
    /// review comes due during a demo.
    @AppStorage("hootReviewDemoMode") private var isReviewDemoModeOn = false
    let theme: WaitWhatTheme
    let onGoBack: () -> Void

    @State private var isVoiceListExpanded = false
    @State private var isPermissionListExpanded = false
    /// "forget everything" needs a second tap; this is true between the two.
    @State private var isForgetEverythingAwaitingConfirmation = false
    @State private var forgetConfirmationResetWorkItem: DispatchWorkItem?

    private static let sonnetModelIdentifier = "claude-sonnet-5-5"
    private static let opusModelIdentifier = "claude-opus-5-5"

    private var petName: String { themeStore.mascot.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            backRow
            modelSection
            voiceSection
            buddySection
            appearanceSection
            memorySection
            permissionsSummarySection
        }
        .padding(14)
    }

    // MARK: - Back

    private var backRow: some View {
        Button(action: onGoBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.muted)
                    .frame(width: 18, height: 18)
                Text("settings")
                    .font(.jetBrainsMono(13, weight: .semibold))
                    .foregroundColor(theme.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuPanelSectionLabel(labelText: "model", theme: theme)
            MenuPanelSegmentedControl(
                optionTitles: ["sonnet · fast", "opus · thorough"],
                selectedOptionIndex: hootController.selectedModel == Self.opusModelIdentifier ? 1 : 0,
                theme: theme,
                onSelectOptionIndex: { selectedOptionIndex in
                    hootController.setSelectedModel(
                        selectedOptionIndex == 1 ? Self.opusModelIdentifier : Self.sonnetModelIdentifier
                    )
                }
            )
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuPanelSectionLabel(labelText: "voice", theme: theme)
            voiceSelectField
            if isVoiceListExpanded {
                voiceOptionList
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Text("speed")
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.faint)
                MenuPanelSpeedSlider(
                    speakingSpeed: $voiceSettingsStore.speakingSpeed,
                    minimumSpeakingSpeed: WaitWhatVoiceSettingsStore.minimumSpeakingSpeed,
                    maximumSpeakingSpeed: WaitWhatVoiceSettingsStore.maximumSpeakingSpeed,
                    theme: theme
                )
                Text(String(format: "%.1f×", voiceSettingsStore.speakingSpeed))
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.muted)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.top, 2)
        }
    }

    /// `solid` field, 0.5pt border, r8: voice name · preview · unfold chevrons.
    private var voiceSelectField: some View {
        HStack(spacing: 8) {
            Button(action: toggleVoiceList) {
                HStack {
                    Text(voiceSettingsStore.selectedVoice.displayName)
                        .font(.system(size: 13))
                        .foregroundColor(theme.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                voiceSettingsStore.playVoicePreview(petName: petName)
            }) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("preview this voice")

            Button(action: toggleVoiceList) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.faint)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.solid))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.foreground(opacity: 0.12), lineWidth: 0.5)
        )
    }

    private func toggleVoiceList() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isVoiceListExpanded.toggle()
        }
    }

    private var voiceOptionList: some View {
        VStack(spacing: 0) {
            ForEach(WaitWhatVoice.allCases) { voiceOption in
                MenuPanelHoverButton(theme: theme, action: {
                    voiceSettingsStore.selectedVoice = voiceOption
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVoiceListExpanded = false
                    }
                }) {
                    HStack {
                        Text(voiceOption.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(theme.ink)
                        Spacer()
                        if voiceOption == voiceSettingsStore.selectedVoice {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.foreground(opacity: 0.04))
        )
    }

    // MARK: - Buddy

    private var buddySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuPanelSectionLabel(labelText: "buddy", theme: theme)
            HStack(spacing: 6) {
                ForEach(WaitWhatMascot.allCases) { mascotOption in
                    MenuPanelBuddyTile(
                        mascot: mascotOption,
                        isSelected: mascotOption == themeStore.mascot,
                        theme: theme,
                        onSelect: { themeStore.mascot = mascotOption }
                    )
                }
            }
            HStack {
                Text("always visible")
                    .font(.system(size: 13))
                    .foregroundColor(theme.ink)
                Spacer()
                MenuPanelSwitch(
                    isOn: hootController.isCornerPetEnabled,
                    theme: theme,
                    onToggle: { isNowOn in hootController.setCornerPetEnabled(isNowOn) }
                )
                .help("keep \(petName) dozing in the corner of your screen")
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuPanelSectionLabel(labelText: "appearance", theme: theme)
            MenuPanelSegmentedControl(
                optionTitles: WaitWhatAppearanceSetting.allCases.map(\.rawValue),
                selectedOptionIndex: WaitWhatAppearanceSetting.allCases.firstIndex(of: themeStore.appearanceSetting) ?? 0,
                theme: theme,
                onSelectOptionIndex: { selectedOptionIndex in
                    themeStore.appearanceSetting = WaitWhatAppearanceSetting.allCases[selectedOptionIndex]
                }
            )
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuPanelSectionLabel(labelText: "memory", theme: theme)

            Text(rememberedThingsText)
                .font(.system(size: 13))
                .foregroundColor(theme.ink)

            memorySwitchRow(
                titleText: "nudges",
                isOn: nudgeCenter.areNudgesEnabled,
                helpText: "let \(petName) wave from the corner when a review is due or a video is ready",
                onToggle: { isNowOn in nudgeCenter.areNudgesEnabled = isNowOn }
            )

            memorySwitchRow(
                titleText: "review demo mode",
                isOn: isReviewDemoModeOn,
                helpText: "reviews come due after minutes instead of days",
                onToggle: { isNowOn in isReviewDemoModeOn = isNowOn }
            )

            forgetEverythingButton
                .padding(.top, 2)
        }
    }

    private var rememberedThingsText: String {
        switch memoryStore.entries.count {
        case 0: return "\(petName) doesn't remember anything yet"
        case 1: return "\(petName) remembers 1 thing"
        case let rememberedCount: return "\(petName) remembers \(rememberedCount) things"
        }
    }

    private func memorySwitchRow(titleText: String, isOn: Bool, helpText: String, onToggle: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(titleText)
                .font(.system(size: 13))
                .foregroundColor(theme.ink)
            Spacer()
            MenuPanelSwitch(isOn: isOn, theme: theme, onToggle: onToggle)
                .help(helpText)
        }
    }

    /// Destructive, so it takes two taps: the first turns the row into an
    /// accent "tap again" confirmation that times out after 4 seconds.
    private var forgetEverythingButton: some View {
        MenuPanelHoverButton(theme: theme, cornerRadius: 9, action: handleForgetEverythingTap) {
            HStack(spacing: 6) {
                Image(systemName: isForgetEverythingAwaitingConfirmation ? "exclamationmark.triangle" : "trash")
                    .font(.system(size: 12, weight: .medium))
                Text(isForgetEverythingAwaitingConfirmation ? "tap again to forget it all" : "forget everything")
                    .font(.jetBrainsMono(11.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(isForgetEverythingAwaitingConfirmation ? theme.onAccent : theme.accent)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isForgetEverythingAwaitingConfirmation ? theme.accent : theme.accent.opacity(0.10))
            )
        }
        .help("deletes every saved question, answer and review on this mac")
    }

    private func handleForgetEverythingTap() {
        forgetConfirmationResetWorkItem?.cancel()
        forgetConfirmationResetWorkItem = nil

        guard isForgetEverythingAwaitingConfirmation else {
            withAnimation(.easeInOut(duration: 0.15)) {
                isForgetEverythingAwaitingConfirmation = true
            }
            let resetWorkItem = DispatchWorkItem {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isForgetEverythingAwaitingConfirmation = false
                }
            }
            forgetConfirmationResetWorkItem = resetWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: resetWorkItem)
            return
        }

        MemoryStore.shared.forgetEverything()
        RecentQuestionsStore.shared.clearAllRecentQuestions()
        withAnimation(.easeInOut(duration: 0.15)) {
            isForgetEverythingAwaitingConfirmation = false
        }
    }

    // MARK: - Permissions

    /// `fg@0.04` r9 row: status dot + "permissions" · "n of 4 on". Tapping
    /// expands the same list as onboarding.
    private var permissionsSummarySection: some View {
        VStack(spacing: 8) {
            MenuPanelHoverButton(theme: theme, cornerRadius: 9, action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPermissionListExpanded.toggle()
                }
            }) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(permissionCenter.allPermissionsGranted ? theme.ok : theme.accent)
                            .frame(width: 7, height: 7)
                        Text("permissions")
                            .font(.system(size: 12.5))
                            .foregroundColor(theme.ink)
                    }
                    Spacer()
                    Text("\(permissionCenter.grantedPermissionCount) of 4 on")
                        .font(.jetBrainsMono(11, weight: .medium))
                        .foregroundColor(theme.muted)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.foreground(opacity: 0.04))
                )
            }

            if isPermissionListExpanded {
                MenuPanelPermissionList(permissionCenter: permissionCenter, theme: theme)
                    .transition(.opacity)
            }
        }
    }
}

/// One buddy tile: pet 48pt + name JBM 10.5. Selected: `solid` with a 2pt
/// accent ring and the name in ink 600; others `fg@0.04`, name muted.
private struct MenuPanelBuddyTile: View {
    let mascot: WaitWhatMascot
    let isSelected: Bool
    let theme: WaitWhatTheme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                PetSpriteView(mascot: mascot, state: .idle, scale: 2)
                Text(mascot.displayName)
                    .font(.jetBrainsMono(10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.ink : theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tileBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            isHovered = isHovering
        }
        .pointerCursor(isEnabled: !isSelected)
    }

    private var tileBackgroundColor: Color {
        if isSelected {
            return theme.solid
        }
        return theme.foreground(opacity: isHovered ? 0.08 : 0.04)
    }
}
