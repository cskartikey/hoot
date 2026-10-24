//
//  MenuPanelOnboardingView.swift
//  Hoot
//
//  Screen 4 of the crisp design: the first thing the menu bar panel shows,
//  until all four permissions are on. The permission group is shared with
//  the settings screen's expandable "permissions" summary.
//

import AppKit
import SwiftUI

struct MenuPanelOnboardingView: View {
    @ObservedObject var permissionCenter: PermissionCenter
    let theme: WaitWhatTheme
    let petName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PetSpriteView(state: .hello, scale: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("hey, i'm \(petName).")
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.19)
                        .foregroundColor(theme.ink)
                    Text("your study buddy")
                        .font(.jetBrainsMono(11, weight: .medium))
                        .foregroundColor(theme.muted)
                }
            }

            onboardingBodyText
                .font(.system(size: 13.5))
                .foregroundColor(theme.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            MenuPanelPermissionList(permissionCenter: permissionCenter, theme: theme)

            Text("nothing runs in the background. i only peek when you ask.")
                .font(.system(size: 11.5))
                .foregroundColor(theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                GeometryReader { trackGeometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.foreground(opacity: 0.08))
                        Capsule()
                            .fill(theme.accent2)
                            .frame(width: trackGeometry.size.width * CGFloat(permissionCenter.grantedPermissionCount) / 4)
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut(duration: 0.3), value: permissionCenter.grantedPermissionCount)

                Text("\(permissionCenter.grantedPermissionCount)/4")
                    .font(.jetBrainsMono(11, weight: .medium))
                    .foregroundColor(theme.muted)
            }
        }
        .padding(20)
    }

    /// "stuck on something? hold ⌃⌥ and ask. …" with ⌃⌥ drawn as an inline
    /// keycap. Text can't draw a rounded box behind a run of characters, so
    /// the keycap is rendered to an image and embedded in the Text.
    private var onboardingBodyText: Text {
        let keycapImageRenderer = ImageRenderer(
            content: WaitWhatKeycap(symbol: "⌃⌥", fontSize: 11.5, theme: theme)
                .padding(.bottom, 1)
        )
        keycapImageRenderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let leadingText = Text("stuck on something? hold ")
        let trailingText = Text(" and ask. i'll explain out loud, point at the thing, and make a little video when it helps.")

        guard let keycapImage = keycapImageRenderer.nsImage else {
            return leadingText + Text("⌃⌥").font(.jetBrainsMono(11.5, weight: .semibold)) + trailingText
        }
        return leadingText + Text(Image(nsImage: keycapImage)).baselineOffset(-5) + trailingText
    }
}

/// The four permission rows in a `fg@0.04` r12 group, separators inset 40.
struct MenuPanelPermissionList: View {
    @ObservedObject var permissionCenter: PermissionCenter
    let theme: WaitWhatTheme

    /// macOS only applies a new screen recording grant after a relaunch, so
    /// once "allow" was pressed the subtitle says so.
    @State private var hasRequestedScreenRecordingPermission = false

    var body: some View {
        VStack(spacing: 0) {
            MenuPanelPermissionRow(
                symbolName: "mic",
                titleText: "microphone",
                permissionRowStatus: permissionCenter.hasMicrophonePermission ? .granted : .allowable,
                theme: theme,
                onAllow: { permissionCenter.requestMicrophonePermission() }
            )
            permissionRowSeparator
            MenuPanelPermissionRow(
                symbolName: "keyboard",
                titleText: "accessibility",
                permissionRowStatus: permissionCenter.hasAccessibilityPermission ? .granted : .allowable,
                theme: theme,
                onAllow: { permissionCenter.requestAccessibilityPermission() },
                secondaryActionTitle: permissionCenter.hasAccessibilityPermission ? nil : "not listed? show the app",
                onSecondaryAction: {
                    // Unsigned dev builds sometimes don't appear in the list;
                    // revealing the app lets the learner drag it in.
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    permissionCenter.openSystemSettingsForAccessibility()
                }
            )
            permissionRowSeparator
            MenuPanelPermissionRow(
                symbolName: "record.circle",
                titleText: "screen recording",
                subtitleText: hasRequestedScreenRecordingPermission && !permissionCenter.hasScreenRecordingPermission
                    ? "reopen hoot after allowing"
                    : "only while keys are held",
                permissionRowStatus: permissionCenter.hasScreenRecordingPermission ? .granted : .allowable,
                theme: theme,
                onAllow: {
                    hasRequestedScreenRecordingPermission = true
                    permissionCenter.requestScreenRecordingPermission()
                }
            )
            permissionRowSeparator
            MenuPanelPermissionRow(
                symbolName: "eye",
                titleText: "screen content",
                permissionRowStatus: screenContentPermissionRowStatus,
                theme: theme,
                onAllow: { permissionCenter.requestScreenContentPermission() }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.foreground(opacity: 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var screenContentPermissionRowStatus: MenuPanelPermissionRowStatus {
        if permissionCenter.hasScreenContentPermission {
            return .granted
        }
        // ScreenCaptureKit's consent prompt only works once screen recording is on.
        return permissionCenter.hasScreenRecordingPermission ? .allowable : .lockedUntilPreviousStep
    }

    private var permissionRowSeparator: some View {
        Rectangle()
            .fill(theme.foreground(opacity: 0.08))
            .frame(height: 0.5)
            .padding(.leading, 40)
    }
}
