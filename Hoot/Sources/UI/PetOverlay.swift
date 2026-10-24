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
/// hoot, one level above the overlay. Click opens the panel; dragging moves
/// hoot's home (the sprite follows on the next frame tick, because the
/// coordinator keeps the dozing hoot on `homeCenterInGlobalSpace()`).
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

        contentView = CornerPetClickTargetView(
            onClick: { [weak self] in self?.onClick?() },
            onDragToNewHomeCenter: { [weak self] newHomeCenter, isDragFinished in
                self?.followDrag(toHomeCenter: newHomeCenter, isDragFinished: isDragFinished)
            }
        )
    }

    /// Moves the window with the mouse right away instead of waiting for the
    /// 0.25s refresh, so the drag doesn't feel laggy.
    private func followDrag(toHomeCenter newHomeCenter: CGPoint, isDragFinished: Bool) {
        PetHomeSpot.moveHome(toCenter: newHomeCenter, persist: isDragFinished)
        let keptHomeCenter = PetHomeSpot.homeCenterInGlobalSpace()
        setFrameOrigin(NSPoint(x: keptHomeCenter.x - Self.sideLength / 2, y: keptHomeCenter.y - Self.sideLength / 2))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CornerPetClickTargetView: NSView {
    /// Mouse travel below this is still a click, so a slightly shaky click
    /// doesn't nudge hoot by a few points.
    private static let distanceThatStartsADrag: CGFloat = 4

    private let onClick: () -> Void
    private let onDragToNewHomeCenter: (_ newHomeCenter: CGPoint, _ isDragFinished: Bool) -> Void

    private var mouseDownLocationInGlobalSpace: CGPoint?
    private var homeCenterAtMouseDown: CGPoint = .zero
    private var isDragging = false

    init(
        onClick: @escaping () -> Void,
        onDragToNewHomeCenter: @escaping (_ newHomeCenter: CGPoint, _ isDragFinished: Bool) -> Void
    ) {
        self.onClick = onClick
        self.onDragToNewHomeCenter = onDragToNewHomeCenter
        super.init(frame: .zero)
        toolTip = "click to open hoot · drag to move it"
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Global mouse location, not the event's window location: the window
        // moves under the mouse while dragging.
        mouseDownLocationInGlobalSpace = NSEvent.mouseLocation
        homeCenterAtMouseDown = PetHomeSpot.homeCenterInGlobalSpace()
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let homeCenterForCurrentDrag = homeCenterForMouse(isDragFinished: false) else { return }
        onDragToNewHomeCenter(homeCenterForCurrentDrag, false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocationInGlobalSpace = nil
            isDragging = false
        }
        if isDragging, let finalHomeCenter = homeCenterForMouse(isDragFinished: true) {
            NSCursor.pop()
            onDragToNewHomeCenter(finalHomeCenter, true)
        } else {
            onClick()
        }
    }

    /// Nil until the mouse has moved far enough to count as a drag.
    private func homeCenterForMouse(isDragFinished: Bool) -> CGPoint? {
        guard let mouseDownLocationInGlobalSpace else { return nil }
        let currentMouseLocation = NSEvent.mouseLocation
        let dragOffset = CGSize(
            width: currentMouseLocation.x - mouseDownLocationInGlobalSpace.x,
            height: currentMouseLocation.y - mouseDownLocationInGlobalSpace.y
        )
        if !isDragging {
            guard hypot(dragOffset.width, dragOffset.height) >= Self.distanceThatStartsADrag else { return nil }
            isDragging = true
            NSCursor.closedHand.push()
        }
        return CGPoint(x: homeCenterAtMouseDown.x + dragOffset.width, y: homeCenterAtMouseDown.y + dragOffset.height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard PetHomeSpot.hasBeenDragged else { return nil }
        let menu = NSMenu()
        let resetItem = NSMenuItem(title: "put hoot back in the corner", action: #selector(putHootBackInTheCorner), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        return menu
    }

    @objc private func putHootBackInTheCorner() {
        PetHomeSpot.resetToDefaultCorner()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
