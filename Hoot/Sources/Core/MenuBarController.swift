//
//  MenuBarController.swift
//  Hoot
//
//  Status item (pet silhouette template icon) + the floating 304pt panel
//  that hosts `MenuPanelView`.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panels refuse key status by default; this one needs it so Esc
/// and any text controls in the settings work without activating the app.
private final class MenuBarFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarController {
    static let panelWidth: CGFloat = 304
    /// Gap between the menu bar and the top of the panel.
    private static let gapBelowStatusItem: CGFloat = 6
    private static let initialPanelHeight: CGFloat = 420
    private static let escapeKeyCode: UInt16 = 53

    private let hootController: HootController
    private let statusItem: NSStatusItem
    private var menuPanel: MenuBarFloatingPanel?

    private var pendingPanelContentHeight: CGFloat?
    private var isPanelResizeScheduled = false
    private var currentPanelContentHeight: CGFloat = MenuBarController.initialPanelHeight

    private var globalMouseDownMonitor: Any?
    private var localEscapeKeyMonitor: Any?
    private var globalEscapeKeyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(hootController: HootController) {
        self.hootController = hootController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let statusItemButton = statusItem.button {
            statusItemButton.target = self
            statusItemButton.action = #selector(statusItemButtonClicked)
            statusItemButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItemButton.toolTip = "hoot"
        }
        updateStatusItemIcon(for: WaitWhatThemeStore.shared.mascot)

        // @Published fires before the store's value changes, so use the
        // value handed to the sink rather than reading the store.
        WaitWhatThemeStore.shared.$mascot
            .removeDuplicates()
            .sink { [weak self] newMascot in self?.updateStatusItemIcon(for: newMascot) }
            .store(in: &cancellables)
        WaitWhatThemeStore.shared.$theme
            .sink { [weak self] newTheme in
                self?.menuPanel?.appearance = NSAppearance(named: newTheme.isDark ? .darkAqua : .aqua)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hootDismissMenuPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hidePanel() }
            .store(in: &cancellables)
    }

    // MARK: - Status item

    private func updateStatusItemIcon(for mascot: WaitWhatMascot) {
        guard let statusItemButton = statusItem.button else { return }
        // A 24px sprite at 0.75pt per pixel is 18pt tall, the menu bar's icon size.
        if let silhouetteImage = PetSpriteLibrary.renderImage(
            for: mascot,
            state: .idle,
            pointsPerPixel: 0.75,
            silhouetteColor: .black
        ) {
            silhouetteImage.isTemplate = true
            statusItemButton.image = silhouetteImage
            statusItemButton.title = ""
        } else {
            // Sprites missing from the bundle: still give the user something to click.
            statusItemButton.image = nil
            statusItemButton.title = mascot.displayName
        }
    }

    @objc private func statusItemButtonClicked() {
        togglePanel()
    }

    // MARK: - Panel

    func togglePanel() {
        if menuPanel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Opens the panel on launch when onboarding still has permissions to ask for.
    func showPanelIfAnyPermissionIsMissing() {
        guard !hootController.permissionCenter.allPermissionsGranted else { return }
        showPanel()
    }

    func showPanel() {
        let panel = menuPanel ?? makeMenuPanel()
        menuPanel = panel
        panel.appearance = WaitWhatThemeStore.shared.nsAppearance
        panel.setFrame(panelFrame(forContentHeight: currentPanelContentHeight), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installDismissMonitors()
    }

    func hidePanel() {
        removeDismissMonitors()
        menuPanel?.orderOut(nil)
    }

    private func makeMenuPanel() -> MenuBarFloatingPanel {
        let panel = MenuBarFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: currentPanelContentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        // The SwiftUI view draws its own glass card and shadow.
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let menuPanelView = MenuPanelView(
            hootController: hootController,
            onContentHeightChange: { [weak self] contentHeight in
                self?.schedulePanelResize(toContentHeight: contentHeight)
            }
        )
        let hostingView = NSHostingView(rootView: menuPanelView)
        // The window size is driven only by onContentHeightChange; letting the
        // hosting view also push its size onto the window is how the
        // constraint-update feedback loop starts.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: currentPanelContentHeight)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    /// Never resize the window from inside SwiftUI's layout pass: setFrame
    /// there triggers another layout pass, and the two can feed each other
    /// until AppKit throws "more Update Constraints in Window passes than
    /// there are views". Remember the latest height and apply it once, after
    /// the current pass, and only when it really changed.
    private func schedulePanelResize(toContentHeight contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        pendingPanelContentHeight = contentHeight.rounded(.up)
        guard !isPanelResizeScheduled else { return }
        isPanelResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingPanelResize()
        }
    }

    private func applyPendingPanelResize() {
        isPanelResizeScheduled = false
        guard let pendingPanelContentHeight else { return }
        self.pendingPanelContentHeight = nil
        guard abs(pendingPanelContentHeight - currentPanelContentHeight) >= 1 else { return }
        currentPanelContentHeight = pendingPanelContentHeight
        guard let menuPanel, menuPanel.isVisible else { return }
        menuPanel.setFrame(panelFrame(forContentHeight: pendingPanelContentHeight), display: true)
    }

    /// Centered under the status item, kept inside the screen, top edge just
    /// below the menu bar so the panel grows downward.
    private func panelFrame(forContentHeight contentHeight: CGFloat) -> NSRect {
        let statusItemFrameOnScreen = statusItem.button?.window?.frame
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let anchorMidX = statusItemFrameOnScreen?.midX ?? (visibleFrame.maxX - Self.panelWidth / 2 - 8)
        let panelTopY = (statusItemFrameOnScreen?.minY ?? visibleFrame.maxY) - Self.gapBelowStatusItem

        let edgeMargin: CGFloat = 8
        var panelOriginX = anchorMidX - Self.panelWidth / 2
        panelOriginX = min(panelOriginX, visibleFrame.maxX - Self.panelWidth - edgeMargin)
        panelOriginX = max(panelOriginX, visibleFrame.minX + edgeMargin)

        return NSRect(x: panelOriginX, y: panelTopY - contentHeight, width: Self.panelWidth, height: contentHeight)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        // Global monitors only see clicks in other apps, which is exactly
        // "outside": clicks inside the panel and on the status item are ours.
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            guard keyEvent.keyCode == Self.escapeKeyCode else { return keyEvent }
            self?.hidePanel()
            return nil
        }
        // The panel doesn't activate the app, so Esc may go to the app
        // underneath; catch it there too.
        globalEscapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            guard keyEvent.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func removeDismissMonitors() {
        for monitor in [globalMouseDownMonitor, localEscapeKeyMonitor, globalEscapeKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouseDownMonitor = nil
        localEscapeKeyMonitor = nil
        globalEscapeKeyMonitor = nil
    }
}
