//
//  PetOverlay.swift
//  Hoot
//
//  One full-screen, transparent, click-through overlay window per display.
//  Together they draw hoot: dozing in the corner of the primary screen,
//  zipping to the cursor as a small head when asked, its bubbles, and its
//  pointing flights. The behaviour lives in PetOverlayCoordinator; what
//  each display draws lives in PetOverlayScreenView.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PetOverlayManager {
    private let hootController: HootController
    private let petOverlayCoordinator: PetOverlayCoordinator
    private var overlayWindows: [PetOverlayWindow] = []
    private var areOverlaysShown = false
    private var themeCancellable: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?

    init(hootController: HootController) {
        self.hootController = hootController
        self.petOverlayCoordinator = PetOverlayCoordinator(hootController: hootController)

        // Keep each window's NSAppearance in step with the theme so the
        // bubbles' `.ultraThinMaterial` renders light or dark to match.
        // `$theme` fires before the store's value changes, so use the
        // emitted theme rather than reading the store back.
        themeCancellable = WaitWhatThemeStore.shared.$theme
            .sink { [weak self] updatedTheme in
                self?.applyAppearance(isDark: updatedTheme.isDark)
            }

        // Displays plugged in, removed, rearranged or resized.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.areOverlaysShown else { return }
                self.rebuildOverlayWindows()
            }
        }
    }

    /// Creates or refreshes one overlay window per screen and shows them.
    func showOverlays() {
        areOverlaysShown = true
        rebuildOverlayWindows()
        petOverlayCoordinator.startFrameTicks()
    }

    func hideOverlays() {
        areOverlaysShown = false
        petOverlayCoordinator.stopFrameTicks()
        for overlayWindow in overlayWindows {
            overlayWindow.orderOut(nil)
        }
        overlayWindows = []
    }

    private func rebuildOverlayWindows() {
        for overlayWindow in overlayWindows {
            overlayWindow.orderOut(nil)
        }
        overlayWindows = NSScreen.screens.map { screen in
            let overlayWindow = PetOverlayWindow(screenFrame: screen.frame)
            overlayWindow.appearance = WaitWhatThemeStore.shared.nsAppearance

            let hostingView = NSHostingView(
                rootView: PetOverlayScreenView(
                    screenFrame: screen.frame,
                    petOverlayCoordinator: petOverlayCoordinator,
                    hootController: hootController
                )
            )
            // The window is sized to its screen; never let SwiftUI resize it.
            hostingView.sizingOptions = []
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            overlayWindow.contentView = hostingView
            overlayWindow.setFrame(screen.frame, display: false)
            overlayWindow.orderFrontRegardless()
            return overlayWindow
        }
    }

    private func applyAppearance(isDark: Bool) {
        let overlayAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for overlayWindow in overlayWindows {
            overlayWindow.appearance = overlayAppearance
        }
    }
}

/// A borderless panel that covers one display, lets every click through,
/// floats above normal windows on every Space (fullscreen ones included,
/// so hoot can answer over a fullscreen video), and never takes focus.
private final class PetOverlayWindow: NSPanel {
    init(screenFrame: CGRect) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
