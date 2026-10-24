//
//  ExplainerSketchView.swift
//  Hoot
//
//  Shows a finished sketch (one model-written HTML page with an inline SVG
//  animated by CSS) inside the explainer panel. A WKWebView with its
//  background turned off so the card's glass shows through, no scroll bars,
//  and every navigation other than the initial file load refused, so a
//  stray link in the markup can never take the panel anywhere.
//
//  The page reads prefers-color-scheme from the web view's effective
//  appearance, which follows the panel's NSAppearance (kept in step with
//  the theme by ExplainerPanelManager), so the sketch flips with the theme.
//

import AppKit
import SwiftUI
import WebKit

struct ExplainerSketchView: NSViewRepresentable {
    /// The sketch page on disk, under the app's sketches directory.
    let sketchFileURL: URL

    func makeCoordinator() -> ExplainerSketchNavigationGate {
        ExplainerSketchNavigationGate()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
        // Sketches are static markup; nothing in them should ever run.
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        webViewConfiguration.preferences.isFraudulentWebsiteWarningEnabled = false

        let sketchWebView = ExplainerSketchWebView(frame: .zero, configuration: webViewConfiguration)
        sketchWebView.navigationDelegate = context.coordinator
        // Private but long-standing: without it the web view paints an
        // opaque white (or black) page behind the transparent SVG.
        sketchWebView.setValue(false, forKey: "drawsBackground")
        sketchWebView.underPageBackgroundColor = .clear
        sketchWebView.allowsMagnification = false
        sketchWebView.allowsBackForwardNavigationGestures = false

        loadSketch(into: sketchWebView, coordinator: context.coordinator)
        return sketchWebView
    }

    func updateNSView(_ sketchWebView: WKWebView, context: Context) {
        // A new sketch for the same panel: swap the page in place.
        if context.coordinator.loadedSketchFileURL != sketchFileURL {
            loadSketch(into: sketchWebView, coordinator: context.coordinator)
        }
    }

    private func loadSketch(into sketchWebView: WKWebView, coordinator: ExplainerSketchNavigationGate) {
        coordinator.loadedSketchFileURL = sketchFileURL
        // Read access is limited to the sketches folder: the page can't pull
        // in anything else from disk even if it tried.
        let readableDirectoryURL = (try? ExplainerSketchClient.sketchesDirectoryURL())
            ?? sketchFileURL.deletingLastPathComponent()
        sketchWebView.loadFileURL(sketchFileURL, allowingReadAccessTo: readableDirectoryURL)
    }
}

/// Lets the initial file load through and refuses every other navigation
/// (links, redirects, form posts), which keeps the panel a picture frame.
final class ExplainerSketchNavigationGate: NSObject, WKNavigationDelegate {
    var loadedSketchFileURL: URL?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isTheSketchItself = navigationAction.request.url?.standardizedFileURL == loadedSketchFileURL?.standardizedFileURL
        let isTheInitialLoad = navigationAction.navigationType == .other && isTheSketchItself
        decisionHandler(isTheInitialLoad ? .allow : .cancel)
    }
}

/// WKWebView that never shows scroll bars or scrolls: a sketch is sized to
/// fit, and a scroll bar flashing on a wheel event looks broken.
final class ExplainerSketchWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Swallow it: the page is the whole picture, there's nowhere to go.
        // Passing it to super would scroll an invisible overflow.
        nextResponder?.scrollWheel(with: event)
    }

    /// Not a drag handle: the panel moves by its background, but dragging
    /// across the picture should not start moving the window.
    override var mouseDownCanMoveWindow: Bool { false }
}
