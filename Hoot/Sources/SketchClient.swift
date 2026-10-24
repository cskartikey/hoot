//
//  SketchClient.swift
//  Hoot
//
//  The fast picture path. When the tutor answers with [SKETCH:brief], this
//  asks the LLM (through the worker's /chat route, non-streaming) for one
//  self-contained HTML page: an inline SVG animated purely with CSS
//  keyframes, in the app's own theme colors, looping every few seconds.
//  The page is checked (it must really be an SVG, with no scripts or
//  network fetches), written to Application Support, and the file URL is
//  handed to the explainer panel to show in a web view. A bad first draft
//  gets one stricter retry; after that the panel shows its failed state.
//
//  Sketches are for "two to five shapes and one motion" ideas. Anything that
//  needs narration, equations building up, or a real simulation still goes
//  to the studio's Manim pipeline.
//

import AppKit
import Foundation
import SwiftUI

enum ExplainerSketchError: LocalizedError {
    case replyWasNotASketch(reason: String)
    case couldNotSaveSketch(underlyingError: Error)

    var errorDescription: String? {
        switch self {
        case .replyWasNotASketch(let reason):
            return "The model's sketch wasn't usable: \(reason)"
        case .couldNotSaveSketch(let underlyingError):
            return "The sketch couldn't be saved: \(underlyingError.localizedDescription)"
        }
    }
}

/// A finished sketch: where the HTML lives, plus what it was drawn for.
struct ExplainerFinishedSketch: Equatable {
    let fileURL: URL
    let question: String
    let brief: String
}

@MainActor
final class ExplainerSketchClient {

    /// Enough for a full page with a dozen animated elements; the prompt
    /// asks for far less, so this is mostly headroom against truncation.
    private let maximumOutputTokensForSketch = 4000
    private let llmClient: LLMClient

    init() {
        llmClient = LLMClient(workerBaseURL: HootController.workerBaseURL, model: HootController.storedSelectedModelName)
    }

    // MARK: - Public API

    /// Writes the sketch for `brief` and returns its file URL. Retries once
    /// with a sterner reminder when the first reply isn't a usable page.
    func makeSketch(brief: String, question: String, spokenAnswer: String) async throws -> ExplainerFinishedSketch {
        let sketchSystemPrompt = Self.sketchSystemPrompt(
            lightTheme: WaitWhatTheme.resolve(isDark: false, mascot: WaitWhatThemeStore.shared.mascot),
            darkTheme: WaitWhatTheme.resolve(isDark: true, mascot: WaitWhatThemeStore.shared.mascot)
        )
        let sketchUserPrompt = Self.sketchUserPrompt(brief: brief, question: question, spokenAnswer: spokenAnswer)

        var validatedSketchHTML: String?
        var lastValidationFailureReason = ""
        for attemptNumber in 1...2 {
            try Task.checkCancellation()
            let userPromptForThisAttempt = attemptNumber == 1
                ? sketchUserPrompt
                : sketchUserPrompt + Self.stricterRetryNudge(previousFailureReason: lastValidationFailureReason)
            let modelReply = try await llmClient.requestPlainTextAnswer(
                systemPrompt: sketchSystemPrompt,
                userPrompt: userPromptForThisAttempt,
                maximumOutputTokens: maximumOutputTokensForSketch
            )
            switch Self.validatedSketchPage(fromModelReply: modelReply) {
            case .success(let sketchHTML):
                validatedSketchHTML = sketchHTML
            case .failure(let reason):
                lastValidationFailureReason = reason
                print("✏️ Sketch attempt \(attemptNumber) rejected: \(reason)")
            }
            if validatedSketchHTML != nil { break }
        }

        guard let validatedSketchHTML else {
            throw ExplainerSketchError.replyWasNotASketch(reason: lastValidationFailureReason)
        }

        let sketchFileURL = try Self.saveSketchPage(validatedSketchHTML)
        print("✏️ Sketch saved: \(sketchFileURL.path)")
        return ExplainerFinishedSketch(fileURL: sketchFileURL, question: question, brief: brief)
    }

    // MARK: - Where sketches live

    /// ~/Library/Application Support/hoot/sketches, created on first use.
    /// The web view is granted read access to this one directory only.
    static func sketchesDirectoryURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let sketchesDirectoryURL = applicationSupportURL
            .appendingPathComponent("hoot", isDirectory: true)
            .appendingPathComponent("sketches", isDirectory: true)
        try FileManager.default.createDirectory(at: sketchesDirectoryURL, withIntermediateDirectories: true)
        return sketchesDirectoryURL
    }

    private static func saveSketchPage(_ sketchHTML: String) throws -> URL {
        do {
            let sketchFileURL = try sketchesDirectoryURL()
                .appendingPathComponent(UUID().uuidString.lowercased())
                .appendingPathExtension("html")
            try sketchHTML.data(using: .utf8)?.write(to: sketchFileURL, options: .atomic)
            return sketchFileURL
        } catch {
            throw ExplainerSketchError.couldNotSaveSketch(underlyingError: error)
        }
    }

    // MARK: - Checking the reply

    enum SketchValidationResult {
        case success(String)
        case failure(String)
    }

    /// Strips code fences and anything chatty around the document, then
    /// insists on a real inline SVG with no way to run code or reach the
    /// network. The page is shown in a WKWebView inside the app, so this is
    /// the whole safety story for model-written markup.
    static func validatedSketchPage(fromModelReply modelReply: String) -> SketchValidationResult {
        var pageText = modelReply.trimmingCharacters(in: .whitespacesAndNewlines)

        // ```html ... ``` wrappers, with or without the language tag.
        if pageText.hasPrefix("```") {
            if let firstLineBreak = pageText.firstIndex(of: "\n") {
                pageText = String(pageText[pageText.index(after: firstLineBreak)...])
            } else {
                pageText = ""
            }
        }
        if pageText.hasSuffix("```") {
            pageText = String(pageText.dropLast(3))
        }
        pageText = pageText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prose before "<!doctype" / "<html" ("here's your sketch:") is dropped.
        let lowercasedPageText = pageText.lowercased()
        if let documentStart = lowercasedPageText.range(of: "<!doctype")?.lowerBound
            ?? lowercasedPageText.range(of: "<html")?.lowerBound {
            let documentStartOffset = lowercasedPageText.distance(from: lowercasedPageText.startIndex, to: documentStart)
            pageText = String(pageText.dropFirst(documentStartOffset))
        }
        if let documentEnd = pageText.range(of: "</html>", options: [.backwards, .caseInsensitive]) {
            pageText = String(pageText[..<documentEnd.upperBound])
        }

        // Inline SVG in HTML doesn't need the namespace, and it is the one
        // legitimate "http" the model keeps adding; drop it rather than fail.
        pageText = pageText.replacingOccurrences(
            of: #"\s+xmlns(?::xlink)?\s*=\s*"[^"]*""#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let lowercasedFinalPageText = pageText.lowercased()
        guard lowercasedFinalPageText.contains("<svg"), lowercasedFinalPageText.contains("</svg>") else {
            return .failure("no complete <svg> element")
        }
        guard lowercasedFinalPageText.contains("@keyframes") else {
            return .failure("no @keyframes animation")
        }
        let forbiddenFragments = ["<script", "<iframe", "<object", "<embed", "<link", "@import", "javascript:", "http://", "https://", "url("]
        for forbiddenFragment in forbiddenFragments where lowercasedFinalPageText.contains(forbiddenFragment) {
            return .failure("contains \(forbiddenFragment)")
        }
        return .success(pageText)
    }

    // MARK: - Prompts

    private static func sketchSystemPrompt(lightTheme: WaitWhatTheme, darkTheme: WaitWhatTheme) -> String {
        """
        you draw tiny animated sketches for hoot, a study buddy that lives in the mac menu bar. a tutor just explained something out loud and wants one picture to go with it. you answer with ONE complete html document and nothing else: no prose, no code fences, no explanation.

        the page:
        - <!doctype html>, <html>, <head> with <meta charset="utf-8"> and one <style>, and a <body> holding exactly one <svg viewBox="0 0 640 360" width="100%" height="100%" preserveAspectRatio="xMidYMid meet">. no xmlns attribute (inline svg doesn't need it).
        - html and body: margin 0, height 100%, overflow hidden, background transparent. the svg fills the body. the app draws the card behind the page, so never paint a page background.
        - animation is css only: @keyframes in the <style>, applied to svg elements with transform-box: fill-box and transform-origin set on anything that rotates or scales. no javascript, no <script>, no <animate> or smil, no external files, no <link>, no url(), no images, no web fonts. the only font-family allowed is ui-monospace, monospace.
        - the whole thing loops: every animation uses animation-iteration-count: infinite with one shared duration between 6s and 10s, so the eye can follow the story over and over. ease in and out; hold the key moment for a beat before looping. small delays are fine, but keep all durations equal so the loop stays in sync.
        - at most 12 elements inside the svg (groups count as one when they move together). 2px strokes, round linecaps and joins, no filters, no gradients, no drop shadows.
        - short labels are allowed: at most four <text> elements, each under 14 characters, font-size 16 to 22, font-family ui-monospace, monospace. a number that changes (like a readout sliding from 1 to 0) is best faked with two or three stacked texts fading in and out in turn.

        colors: use only these, as css custom properties set on :root, and nothing else. define the light values on :root and override them under @media (prefers-color-scheme: dark) so the sketch reads in both appearances.
        light: --ink: \(lightTheme.ink.sketchHexString); --accent: \(lightTheme.accent.sketchHexString); --accent2: \(lightTheme.accent2.sketchHexString); --paper: \(lightTheme.pageBackground.sketchHexString);
        dark: --ink: \(darkTheme.ink.sketchHexString); --accent: \(darkTheme.accent.sketchHexString); --accent2: \(darkTheme.accent2.sketchHexString); --paper: \(darkTheme.pageBackground.sketchHexString);
        use --ink for most strokes and labels, --accent for the one thing that moves or matters most, --accent2 for a second actor or a result, and --paper only as a fill when a shape must cover something behind it. opacity between 0.25 and 1 is fine for grids and ghosts.

        the picture:
        - one idea, one motion. read the brief and the tutor's spoken words, then draw the simplest thing that makes the idea click: two to five shapes and one thing changing. think of a chalkboard sketch, not a diagram.
        - leave the story readable at 318 by 180 points: big shapes, generous spacing, nothing near the edges (keep a 24 unit margin inside the viewbox).
        - a before state, a change, and an after state that lingers. a ghost (dashed, low opacity) of the "before" left behind helps show what changed.
        """
    }

    private static func sketchUserPrompt(brief: String, question: String, spokenAnswer: String) -> String {
        var promptLines = ["brief: \(brief)", "", "the learner asked: \(question)"]
        if !spokenAnswer.isEmpty {
            promptLines.append("")
            promptLines.append("what the tutor said out loud: \(spokenAnswer)")
        }
        promptLines.append("")
        promptLines.append("reply with the html document only.")
        return promptLines.joined(separator: "\n")
    }

    private static func stricterRetryNudge(previousFailureReason: String) -> String {
        """


        your previous reply was rejected (\(previousFailureReason)). this time: start with <!doctype html> and end with </html>, put exactly one <svg viewBox="0 0 640 360"> in the body, animate with @keyframes in a <style> block, and include no <script>, no links, no urls, no code fences and no words outside the document.
        """
    }
}

// MARK: - Theme colors as hex, for the prompt

private extension Color {
    /// "#rrggbb" in sRGB. Theme colors are plain opaque sRGB values, so a
    /// failed conversion (never seen) falls back to mid grey rather than crash.
    var sketchHexString: String {
        guard let sRGBColor = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        let redComponent = Int((sRGBColor.redComponent * 255).rounded())
        let greenComponent = Int((sRGBColor.greenComponent * 255).rounded())
        let blueComponent = Int((sRGBColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", redComponent, greenComponent, blueComponent)
    }
}
