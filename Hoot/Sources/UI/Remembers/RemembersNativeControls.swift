//
//  RemembersNativeControls.swift
//  Hoot
//
//  The native AppKit pieces of the remembers window: the search field
//  (a real NSSearchField with its own magnifier and clear button), the
//  behind-window material, and small text helpers (search highlights, the
//  inline ⌃⌥ keycap).
//

import AppKit
import SwiftUI

// MARK: - Search field

/// NSSearchField bridged into SwiftUI. Filters on every keystroke; the
/// built-in cancel button and Esc clear it. Bumping `focusRequestCount`
/// makes it first responder (⌘F).
struct RemembersNativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholderText: String
    let isEnabled: Bool
    let focusRequestCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholderText
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .exterior
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldChanged(_:))
        searchField.setAccessibilityLabel("search what you've asked")
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        if searchField.placeholderString != placeholderText {
            searchField.placeholderString = placeholderText
        }
        searchField.isEnabled = isEnabled
        if context.coordinator.lastHandledFocusRequestCount != focusRequestCount {
            context.coordinator.lastHandledFocusRequestCount = focusRequestCount
            // After this layout pass, so a field that just appeared is in a window.
            DispatchQueue.main.async {
                searchField.window?.makeFirstResponder(searchField)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastHandledFocusRequestCount = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        /// The cancel button (and Esc) send the action with an empty string.
        @objc func searchFieldChanged(_ searchField: NSSearchField) {
            if text.wrappedValue != searchField.stringValue {
                text.wrappedValue = searchField.stringValue
            }
        }
    }
}

// MARK: - Window material

/// Behind-window blur for the window background (the `glass` tint is laid
/// over it in SwiftUI). Always active, so the window doesn't go flat grey
/// when another app is in front.
struct RemembersWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .underWindowBackground
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {}
}

// MARK: - Text helpers

enum RemembersText {
    /// `text` with `highlightedRange` on the search-highlight background.
    static func highlighted(_ text: String, range highlightedRange: Range<String.Index>?, theme: WaitWhatTheme) -> AttributedString {
        guard let highlightedRange else { return AttributedString(text) }
        var attributedText = AttributedString(text[..<highlightedRange.lowerBound])
        var highlightedPart = AttributedString(text[highlightedRange])
        highlightedPart.backgroundColor = theme.searchHighlight
        attributedText.append(highlightedPart)
        attributedText.append(AttributedString(text[highlightedRange.upperBound...]))
        return attributedText
    }

    /// The ⌃⌥ keycap as an inline image, so it can sit inside a wrapping
    /// sentence ("hold ⌃⌥ and ask…") the way the design draws it.
    @MainActor
    static func keycapImage(theme: WaitWhatTheme) -> Image {
        let keycapRenderer = ImageRenderer(content: WaitWhatKeycap(symbol: "⌃⌥", theme: theme).padding(.horizontal, 1))
        keycapRenderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let keycapImage = keycapRenderer.nsImage {
            return Image(nsImage: keycapImage)
        }
        return Image(systemName: "keyboard")
    }

    /// "hold [⌃⌥] and …" as one wrapping Text.
    @MainActor
    static func sentenceWithKeycap(before: String, after: String, theme: WaitWhatTheme) -> Text {
        Text(before) + Text(keycapImage(theme: theme)).baselineOffset(-5) + Text(after)
    }
}
