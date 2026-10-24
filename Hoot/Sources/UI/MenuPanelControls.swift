//
//  MenuPanelControls.swift
//  Hoot
//
//  The small controls the menu bar panel is built from, drawn to the crisp
//  design (screens 2–4): hover-fill buttons, the segmented control, the
//  speed slider, the "always visible" switch, recent-question rows and
//  permission rows. Every color comes from the WaitWhatTheme passed in.
//

import SwiftUI

// MARK: - Shared bits

/// 0.5pt `fg@0.10` separator, inset 8 like the design.
struct MenuPanelHairline: View {
    let theme: WaitWhatTheme

    var body: some View {
        Rectangle()
            .fill(theme.foreground(opacity: 0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 8)
    }
}

/// Section label: JBM 10.5/500 in `faint` ("recent", "model", "voice"…).
struct MenuPanelSectionLabel: View {
    let labelText: String
    let theme: WaitWhatTheme

    var body: some View {
        Text(labelText)
            .font(.jetBrainsMono(10.5, weight: .medium))
            .foregroundColor(theme.faint)
    }
}

/// A plain button with the panel's hover fill (`fg@0.06`) and the
/// pointing-hand cursor. The label stretches to the full row width.
struct MenuPanelHoverButton<ButtonLabel: View>: View {
    let theme: WaitWhatTheme
    var cornerRadius: CGFloat = 7
    let action: () -> Void
    @ViewBuilder let label: () -> ButtonLabel

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovered ? theme.foreground(opacity: 0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            isHovered = isHovering
        }
        .pointerCursor()
    }
}

/// A capsule action pill (e.g. "allow"): JBM 11.5/600, on-accent on accent,
/// slightly brighter on hover.
struct MenuPanelAccentPillButton: View {
    let titleText: String
    let theme: WaitWhatTheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(titleText)
                .font(.jetBrainsMono(11.5, weight: .semibold))
                .foregroundColor(theme.onAccent)
                .padding(.vertical, 4)
                .padding(.horizontal, 11)
                .background(Capsule().fill(theme.accent))
                .overlay(Capsule().fill(Color.white.opacity(isHovered ? 0.12 : 0)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            isHovered = isHovering
        }
        .pointerCursor()
    }
}

// MARK: - Segmented control

/// `fg@0.06` track (r8, 2pt inset); the selected segment sits on `seg` with
/// a small shadow (r6) and slides between options.
struct MenuPanelSegmentedControl: View {
    let optionTitles: [String]
    let selectedOptionIndex: Int
    let theme: WaitWhatTheme
    let onSelectOptionIndex: (Int) -> Void

    @Namespace private var selectedSegmentNamespace
    @State private var hoveredOptionIndex: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(optionTitles.enumerated()), id: \.offset) { optionIndex, optionTitle in
                let isSelectedOption = optionIndex == selectedOptionIndex
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        onSelectOptionIndex(optionIndex)
                    }
                }) {
                    Text(optionTitle)
                        .font(.system(size: 12.5, weight: isSelectedOption ? .medium : .regular))
                        .foregroundColor(isSelectedOption ? theme.ink : theme.ink2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if isSelectedOption {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.segmentSelected)
                                    .shadow(color: theme.shadowColor.opacity(0.18), radius: 1, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "selectedSegment", in: selectedSegmentNamespace)
                            } else if hoveredOptionIndex == optionIndex {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.foreground(opacity: 0.06))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredOptionIndex = isHovering ? optionIndex : (hoveredOptionIndex == optionIndex ? nil : hoveredOptionIndex)
                }
                .pointerCursor(isEnabled: !isSelectedOption)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.foreground(opacity: 0.06))
        )
    }
}

// MARK: - Speed slider

/// 4pt `fg@0.10` track, accent fill, 16pt white knob. Snaps to 0.1 steps,
/// since smaller speed changes are hard to hear.
struct MenuPanelSpeedSlider: View {
    @Binding var speakingSpeed: Double
    let minimumSpeakingSpeed: Double
    let maximumSpeakingSpeed: Double
    let theme: WaitWhatTheme

    private let knobDiameter: CGFloat = 16

    var body: some View {
        GeometryReader { sliderGeometry in
            let knobTravelWidth = max(sliderGeometry.size.width - knobDiameter, 1)
            let filledFraction = (speakingSpeed - minimumSpeakingSpeed) / (maximumSpeakingSpeed - minimumSpeakingSpeed)
            let knobCenterX = knobDiameter / 2 + knobTravelWidth * CGFloat(min(max(filledFraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.foreground(opacity: 0.10))
                    .frame(height: 4)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: knobCenterX, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: Color.black.opacity(0.3), radius: 1.5, x: 0, y: 1)
                    .offset(x: knobCenterX - knobDiameter / 2)
            }
            .frame(height: knobDiameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragValue in
                        let draggedFraction = min(max((dragValue.location.x - knobDiameter / 2) / knobTravelWidth, 0), 1)
                        let unsnappedSpeed = minimumSpeakingSpeed + Double(draggedFraction) * (maximumSpeakingSpeed - minimumSpeakingSpeed)
                        let snappedSpeed = (unsnappedSpeed * 10).rounded() / 10
                        if abs(snappedSpeed - speakingSpeed) > 0.001 {
                            speakingSpeed = snappedSpeed
                        }
                    }
            )
        }
        .frame(height: knobDiameter)
        .pointerCursor()
    }
}

// MARK: - Switch

/// The design's 30×18 switch: `ok` green when on, `fg@0.12` when off, with
/// a 14pt white knob.
struct MenuPanelSwitch: View {
    let isOn: Bool
    let theme: WaitWhatTheme
    let onToggle: (Bool) -> Void

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                onToggle(!isOn)
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? theme.ok : theme.foreground(opacity: 0.12))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Recent question row

/// SF Symbol (17pt) · [title SF 13 ink, meta JBM 10.5 muted]. The most recent
/// row is tinted `accent@0.12`; the others get a hover fill.
struct MenuPanelRecentQuestionRow: View {
    let symbolName: String
    let symbolColor: Color
    let titleText: String
    let metaText: String
    let isMostRecent: Bool
    let theme: WaitWhatTheme

    @State private var isHovered = false

    var body: some View {
        // Reopening a saved answer isn't built yet, so the rows aren't buttons
        // (no pointer cursor); they only acknowledge the hover.
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundColor(symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.system(size: 13))
                    .foregroundColor(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metaText)
                    .font(.jetBrainsMono(10.5))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .onHover { isHovering in
            isHovered = isHovering
        }
    }

    private var rowBackgroundColor: Color {
        if isMostRecent {
            return theme.accent.opacity(0.12)
        }
        return isHovered ? theme.foreground(opacity: 0.06) : Color.clear
    }
}

// MARK: - Permission row

enum MenuPanelPermissionRowStatus {
    case granted
    case allowable
    /// Screen content only works once screen recording is on.
    case lockedUntilPreviousStep
}

/// One row of the permission group: icon · title (+ subtitle) · status
/// ("on" in accent2, an "allow" pill, or a dimmed "next").
struct MenuPanelPermissionRow: View {
    let symbolName: String
    let titleText: String
    var subtitleText: String? = nil
    let permissionRowStatus: MenuPanelPermissionRowStatus
    let theme: WaitWhatTheme
    let onAllow: () -> Void
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundColor(symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 13))
                    .foregroundColor(theme.ink)
                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let secondaryActionTitle, let onSecondaryAction {
                    Button(action: onSecondaryAction) {
                        Text(secondaryActionTitle)
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            Spacer(minLength: 0)

            statusView
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .opacity(permissionRowStatus == .lockedUntilPreviousStep ? 0.45 : 1)
    }

    private var symbolColor: Color {
        switch permissionRowStatus {
        case .granted: return theme.accent2
        case .allowable: return theme.accent
        case .lockedUntilPreviousStep: return theme.muted
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch permissionRowStatus {
        case .granted:
            Text("on")
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(theme.accent2)
        case .allowable:
            MenuPanelAccentPillButton(titleText: "allow", theme: theme, action: onAllow)
        case .lockedUntilPreviousStep:
            Text("next")
                .font(.jetBrainsMono(11, weight: .medium))
                .foregroundColor(theme.muted)
        }
    }
}
