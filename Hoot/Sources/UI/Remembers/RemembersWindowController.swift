//
//  RemembersWindowController.swift
//  Hoot
//
//  Owns the single "what hoot remembers" window: a real titled NSWindow
//  (traffic lights, transparent titlebar over full-size content, 520×600,
//  not resizable). Opening again brings the same window to the front, and
//  opening on a concept navigates it there. Its appearance and title
//  follow WaitWhatThemeStore. Esc / ⌘W close it, ⌘F focuses search.
//

import AppKit
import Combine
import SwiftUI

/// Handles the window-level keys the accessory app has no menu for.
private final class RemembersWindow: NSWindow {
    var onFindRequested: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags == .command, let typedCharacters = event.charactersIgnoringModifiers?.lowercased() {
            switch typedCharacters {
            case "w":
                performClose(nil)
                return true
            case "f":
                onFindRequested?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class RemembersWindowController: NSObject, NSWindowDelegate {
    static let shared = RemembersWindowController()

    private let model = RemembersWindowModel()
    private var remembersWindow: RemembersWindow?
    private var themeCancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
    }

    /// Opens (or focuses) the window, on a concept's detail if given.
    /// Activates hoot so the window takes focus even though hoot is a
    /// menu-bar app, and closes the menu panel.
    func show(hootController: HootController, focusingConcept concept: String? = nil) {
        model.hootController = hootController
        NotificationCenter.default.post(name: .hootDismissMenuPanel, object: nil)

        let window = remembersWindow ?? makeWindow(hootController: hootController)
        if let concept, MemoryStore.shared.conceptReview(forConcept: concept) != nil {
            model.openConceptDetail(MemoryStore.normalizedConcept(concept))
        }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(hootController: HootController) -> RemembersWindow {
        let windowSize = RemembersWindowView.windowSize
        let window = RemembersWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // The SwiftUI root paints the behind-window material + glass tint.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.onFindRequested = { [weak self] in self?.model.requestSearchFocus() }

        let hostingView = NSHostingView(rootView: RemembersWindowView(model: model, hootController: hootController))
        // Fixed-size window: never let SwiftUI drive the window size (hoot's
        // panels crashed on constraint-update loops when it did).
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        window.contentView = hostingView
        window.setContentSize(windowSize)

        applyTheme(WaitWhatThemeStore.shared.theme, to: window)
        // `$theme` fires before the store's value changes, so use the new value.
        WaitWhatThemeStore.shared.$theme
            .sink { [weak self, weak window] newTheme in
                guard let self, let window else { return }
                self.applyTheme(newTheme, to: window)
            }
            .store(in: &themeCancellables)

        remembersWindow = window
        return window
    }

    private func applyTheme(_ theme: WaitWhatTheme, to window: NSWindow) {
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.title = "what \(theme.mascot.displayName) remembers"
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.expandedAnswerEntryId = nil
    }
}
