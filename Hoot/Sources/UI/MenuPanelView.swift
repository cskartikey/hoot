//
//  MenuPanelView.swift
//  Hoot
//
//  The menu bar panel's content (crisp design screens 2–4), one 304pt glass
//  card: onboarding / permissions until all four are on, then home ⇄
//  settings (pushed, 0.25s ease). Every color comes from WaitWhatThemeStore,
//  so light / dark and each mascot re-theme the panel live.
//
//  The card reports its natural height through `onContentHeightChange`; the
//  menu bar controller resizes its panel to match (asynchronously). The card
//  sizes itself vertically and pins to the top, so a window that is briefly
//  taller or shorter during that resize never feeds back into the measurement.
//

import SwiftUI

struct MenuPanelView: View {
    @ObservedObject var hootController: HootController
    /// Called with the content's natural height so the panel can resize.
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    @ObservedObject private var themeStore = WaitWhatThemeStore.shared

    static let panelWidth: CGFloat = 304

    var body: some View {
        MenuPanelCardView(
            hootController: hootController,
            permissionCenter: hootController.permissionCenter,
            theme: themeStore.theme,
            petName: themeStore.mascot.displayName
        )
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { newContentHeight in
            onContentHeightChange(newContentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, themeStore.theme.isDark ? .dark : .light)
    }
}

private enum MenuPanelScreen {
    case home
    case settings
}

/// Split from MenuPanelView so it can observe the PermissionCenter (a
/// separate ObservableObject owned by the controller) directly.
private struct MenuPanelCardView: View {
    @ObservedObject var hootController: HootController
    @ObservedObject var permissionCenter: PermissionCenter
    let theme: WaitWhatTheme
    let petName: String

    @State private var currentScreen: MenuPanelScreen = .home
    /// True for a moment right after the last permission is granted, so the
    /// home header pet waves hello before settling into idle.
    @State private var isWavingHelloAfterOnboarding = false

    private let panelPushAnimation = Animation.easeInOut(duration: 0.25)

    var body: some View {
        ZStack(alignment: .top) {
            if !permissionCenter.allPermissionsGranted {
                MenuPanelOnboardingView(permissionCenter: permissionCenter, theme: theme, petName: petName)
                    .transition(.opacity)
            } else if currentScreen == .home {
                MenuPanelHomeView(
                    hootController: hootController,
                    theme: theme,
                    petName: petName,
                    isWavingHelloAfterOnboarding: isWavingHelloAfterOnboarding,
                    onOpenSettings: {
                        withAnimation(panelPushAnimation) {
                            currentScreen = .settings
                        }
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                MenuPanelSettingsView(
                    hootController: hootController,
                    permissionCenter: permissionCenter,
                    theme: theme,
                    onGoBack: {
                        withAnimation(panelPushAnimation) {
                            currentScreen = .home
                        }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: MenuPanelView.panelWidth, alignment: .top)
        .clipped()
        .waitWhatGlassPanel(theme: theme)
        .animation(.easeInOut(duration: 0.3), value: permissionCenter.allPermissionsGranted)
        .onChange(of: permissionCenter.allPermissionsGranted) { _, areAllPermissionsGrantedNow in
            guard areAllPermissionsGrantedNow else { return }
            currentScreen = .home
            isWavingHelloAfterOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                isWavingHelloAfterOnboarding = false
            }
        }
    }
}
