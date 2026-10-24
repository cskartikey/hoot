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
    /// A small clickable window over the dozing corner hoot (the overlay
    /// itself lets every click through).
    private var cornerPetClickTargetWindow: CornerPetClickTargetWindow?
    private var cornerPetClickTargetRefreshTimer: Timer?

    /// Called when the user clicks the corner hoot.
    var onCornerPetClicked: (() -> Void)?

    /// Whether the full hoot is dozing in the corner right now (overlays
    /// shown, phase .home, corner hoot allowed). Corner nudges sit beside it
    /// when true and fall back to the screen corner when false.
    private(set) static var isCornerHootDozingOnScreen = false
    /// Redraws the corner hoot in its `hello` pose while a nudge is up.
    private var nudgeCancellable: AnyCancellable?

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

        // The coordinator reads `NudgeCenter.shared.currentNudge` for the
        // pose; nudges aren't part of its published state, so tell its
        // views to re-render whenever a nudge comes or goes.
        nudgeCancellable = NudgeCenter.shared.$currentNudge
            .map { $0?.id }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.petOverlayCoordinator.objectWillChange.send()
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
        startCornerPetClickTarget()
    }

    func hideOverlays() {
        areOverlaysShown = false
        Self.isCornerHootDozingOnScreen = false
        petOverlayCoordinator.stopFrameTicks()
        cornerPetClickTargetRefreshTimer?.invalidate()
        cornerPetClickTargetRefreshTimer = nil
        cornerPetClickTargetWindow?.orderOut(nil)
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

    // MARK: - Corner hoot click target

    private func startCornerPetClickTarget() {
        if cornerPetClickTargetWindow == nil {
            let clickTargetWindow = CornerPetClickTargetWindow()
            clickTargetWindow.onClick = { [weak self] in self?.onCornerPetClicked?() }
            cornerPetClickTargetWindow = clickTargetWindow
        }
        cornerPetClickTargetRefreshTimer?.invalidate()
        // Cheap: just follows whether hoot is dozing at home and where home is.
        cornerPetClickTargetRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCornerPetClickTarget() }
        }
        refreshCornerPetClickTarget()
    }

    private func refreshCornerPetClickTarget() {
        guard let cornerPetClickTargetWindow else { return }
        let isHootDozingInCorner = areOverlaysShown
            && petOverlayCoordinator.phase == .home
            && petOverlayCoordinator.isCornerHootAllowed
        Self.isCornerHootDozingOnScreen = isHootDozingInCorner
        guard isHootDozingInCorner else {
            if cornerPetClickTargetWindow.isVisible { cornerPetClickTargetWindow.orderOut(nil) }
            return
        }
        let homeCenter = PetOverlayCoordinator.homeCenterInGlobalSpace()
        let clickTargetSide = CornerPetClickTargetWindow.sideLength
        let clickTargetFrame = NSRect(
            x: homeCenter.x - clickTargetSide / 2,
            y: homeCenter.y - clickTargetSide / 2,
            width: clickTargetSide,
            height: clickTargetSide
        )
        if cornerPetClickTargetWindow.frame != clickTargetFrame {
            cornerPetClickTargetWindow.setFrame(clickTargetFrame, display: false)
        }
        if !cornerPetClickTargetWindow.isVisible {
            cornerPetClickTargetWindow.orderFrontRegardless()
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

/// An invisible, clickable square sitting exactly over the dozing corner
/// hoot, one level above the overlay. Shows the pointing hand on hover.
private final class CornerPetClickTargetWindow: NSPanel {
    static let sideLength: CGFloat = 52

    var onClick: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.sideLength, height: Self.sideLength),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        // Fully clear windows don't receive clicks, so keep a whisper of alpha.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        contentView = CornerPetClickTargetView(onClick: { [weak self] in self?.onClick?() })
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CornerPetClickTargetView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        toolTip = "open hoot"
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
