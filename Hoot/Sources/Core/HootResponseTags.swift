//
//  HootResponseTags.swift
//  Hoot
//
//  Pulls the machine-readable tags out of the tutor's answer:
//    [VIDEO:brief]                 → ask the studio for an explainer video
//    [POINT:x,y,w,h:label(:screenN)] → box the thing (top-left x,y + size)
//    [POINT:x,y:label(:screenN)]   → older point form (center only)
//    [POINT:none]                  → nothing to point at
//    [CONCEPT:words]               → what to remember this question under
//    [CONCEPT:none]                → chit-chat, don't remember
//    [REVIEW:remembered|shaky|forgot] → the grade of a spaced-review answer
//  None of them is ever spoken: speech stops at the first "[".
//  and maps a point from screenshot pixels to AppKit global coordinates.
//

import AppKit
import Foundation

/// A place the tutor asked hoot to point at, still in screenshot pixel space.
struct HootPointingTarget: Equatable {
    /// Center of the target, in screenshot pixels.
    let pixelX: Double
    let pixelY: Double
    /// Size of the element's box in screenshot pixels, when the tutor gave one.
    let pixelWidth: Double?
    let pixelHeight: Double?
    let label: String?
    /// 1-based screen number from the image label, when the tutor gave one.
    let screenNumber: Int?
}

/// A pointing target resolved to a real place on the user's displays.
struct HootResolvedPointingLocation: Equatable {
    /// AppKit global coordinates (points, bottom-left origin).
    let globalLocation: CGPoint
    let displayFrame: CGRect
    /// The element's size in points, when the tutor boxed it.
    let globalBoxSize: CGSize?
}

enum HootResponseTags {

    /// Only the text before the first "[" is ever spoken. Tags always come at
    /// the end, so this is the same rule the streaming speech uses, which keeps
    /// the "already enqueued" character count valid against the final text.
    // MARK: - Walkthrough
    // The one exception: walkthrough [STEP n/N POINT:...] tags sit inline
    // BEFORE each sentence, so they are stripped first (each becomes one
    // space, prefix-stable as the stream grows) and the cut happens at the
    // first tag that is not a step tag.
    static func speakableText(from responseText: String) -> String {
        let textWithoutStepTags = HootWalkthroughTags.stripStepTags(from: responseText).strippedText
        if let firstTagStart = textWithoutStepTags.firstIndex(of: "[") {
            return String(textWithoutStepTags[..<firstTagStart])
        }
        return textWithoutStepTags
    }

    /// Finds a [VIDEO:brief] tag anywhere in the response and removes it,
    /// so the brief is never spoken aloud.
    static func parseExplainerVideoRequest(from responseText: String) -> (textWithoutVideoTag: String, explainerVideoBrief: String?) {
        let pattern = #"\[VIDEO:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let briefRange = Range(match.range(at: 1), in: responseText),
              let fullTagRange = Range(match.range, in: responseText) else {
            return (responseText, nil)
        }
        let explainerVideoBrief = String(responseText[briefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var textWithoutVideoTag = responseText
        textWithoutVideoTag.removeSubrange(fullTagRange)
        return (textWithoutVideoTag, explainerVideoBrief)
    }

    /// The concept from [CONCEPT:words], normalized ("Determinants." →
    /// "determinants"), or nil for [CONCEPT:none], a missing tag, or
    /// something too long to be a concept name.
    static func parseConcept(from responseText: String) -> String? {
        guard let rawConcept = firstTagValue(named: "CONCEPT", in: responseText) else { return nil }
        let normalizedConcept = MemoryStore.normalizedConcept(rawConcept)
        let conceptWordCount = normalizedConcept.split(separator: " ").count
        guard !normalizedConcept.isEmpty,
              !["none", "n/a", "na", "nothing", "chit-chat", "chitchat"].contains(normalizedConcept),
              conceptWordCount <= 5,
              normalizedConcept.count <= 48 else { return nil }
        return normalizedConcept
    }

    /// True when the reply carries [PREDICT]: hoot asked for a guess instead
    /// of answering, and the learner's next hold is that guess.
    static func hasPredictionTag(in responseText: String) -> Bool {
        responseText.range(of: #"\[PREDICT\s*\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The question from [CHECK:question], or nil when there is none (or it
    /// is empty / implausibly long).
    static func parseQuickCheckQuestion(from responseText: String) -> String? {
        guard let rawQuestion = firstTagValue(named: "CHECK", in: responseText) else { return nil }
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, trimmedQuestion.lowercased() != "none", trimmedQuestion.count <= 240 else { return nil }
        return trimmedQuestion
    }

    /// The grade from [REVIEW:remembered|shaky|forgot], or nil.
    static func parseReviewResult(from responseText: String) -> ReviewResult? {
        guard let rawReviewResult = firstTagValue(named: "REVIEW", in: responseText) else { return nil }
        let normalizedReviewResult = rawReviewResult.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exactReviewResult = ReviewResult(rawValue: normalizedReviewResult) { return exactReviewResult }
        // Tolerate small variations ("forgotten", "shaky-ish").
        if normalizedReviewResult.hasPrefix("remember") { return .remembered }
        if normalizedReviewResult.hasPrefix("shak") { return .shaky }
        if normalizedReviewResult.hasPrefix("forg") { return .forgot }
        return nil
    }

    /// The text inside the first [NAME:...] tag, case-insensitive on NAME.
    private static func firstTagValue(named tagName: String, in responseText: String) -> String? {
        let pattern = #"\["# + tagName + #"\s*:\s*([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let valueRange = Range(match.range(at: 1), in: responseText) else { return nil }
        return String(responseText[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First ~two sentences of the spoken answer, for the memory's summary.
    static func answerSummary(fromSpokenText spokenText: String, maximumSentenceCount: Int = 2, maximumLength: Int = 280) -> String {
        let trimmedSpokenText = spokenText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var summary = ""
        var sentenceCount = 0
        var previousCharacter: Character?
        for character in trimmedSpokenText {
            // A sentence ends at . ! ? followed by whitespace.
            if let previousCharacter, ".!?".contains(previousCharacter), character.isWhitespace {
                sentenceCount += 1
                if sentenceCount >= maximumSentenceCount { break }
            }
            summary.append(character)
            previousCharacter = character
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.count > maximumLength {
            summary = String(summary.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return summary
    }

    /// Reads the last [POINT:...] tag in the response. Returns nil for
    /// [POINT:none], a missing tag, or a tag we can't make sense of — in all
    /// of those cases hoot simply doesn't point.
    static func parsePointingTarget(from responseText: String) -> HootPointingTarget? {
        // Accepts decimals and stray spaces ("[POINT: 640 , 380 : the grid ]")
        // because models aren't perfectly consistent about the format.
        let numberPattern = #"(-?\d+(?:\.\d+)?)"#
        let pattern = #"\[POINT:\s*"# + numberPattern + #"\s*,\s*"# + numberPattern
            + #"(?:\s*,\s*"# + numberPattern + #"\s*,\s*"# + numberPattern + #")?\s*(?::([^\]]*))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)
        guard let lastMatch = regex.matches(in: responseText, range: wholeRange).last,
              let xRange = Range(lastMatch.range(at: 1), in: responseText),
              let yRange = Range(lastMatch.range(at: 2), in: responseText),
              let firstNumber = Double(responseText[xRange]),
              let secondNumber = Double(responseText[yRange]) else {
            return nil
        }

        // Four numbers = a box (top-left + size); two = a center point.
        var pixelX = firstNumber
        var pixelY = secondNumber
        var pixelWidth: Double?
        var pixelHeight: Double?
        if let widthRange = Range(lastMatch.range(at: 3), in: responseText),
           let heightRange = Range(lastMatch.range(at: 4), in: responseText),
           let boxWidth = Double(responseText[widthRange]),
           let boxHeight = Double(responseText[heightRange]),
           boxWidth > 0, boxHeight > 0 {
            pixelWidth = boxWidth
            pixelHeight = boxHeight
            pixelX = firstNumber + boxWidth / 2
            pixelY = secondNumber + boxHeight / 2
        }

        // The part after the coordinates is "label" or "label:screenN".
        var label: String?
        var screenNumber: Int?
        if let labelAndScreenRange = Range(lastMatch.range(at: 5), in: responseText) {
            var labelComponents = responseText[labelAndScreenRange]
                .split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let lastComponent = labelComponents.last,
               let parsedScreenNumber = screenNumberFromComponent(lastComponent) {
                screenNumber = parsedScreenNumber
                labelComponents.removeLast()
            }
            let joinedLabel = labelComponents.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            label = joinedLabel.isEmpty ? nil : joinedLabel
        }

        return HootPointingTarget(
            pixelX: pixelX,
            pixelY: pixelY,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            label: label,
            screenNumber: screenNumber
        )
    }

    /// "screen2" / "screen 2" → 2.
    private static func screenNumberFromComponent(_ component: String) -> Int? {
        let lowercasedComponent = component.lowercased()
        guard lowercasedComponent.hasPrefix("screen") else { return nil }
        let digits = lowercasedComponent.dropFirst("screen".count).trimmingCharacters(in: .whitespaces)
        return Int(digits)
    }

    /// Maps a target from the screenshot it was given in to AppKit global
    /// coordinates. Screenshots have a top-left origin with y going down;
    /// AppKit has a bottom-left origin with y going up, so y is flipped
    /// against the display's maxY. Screenshots may also be downscaled, so the
    /// pixel position is scaled by display points per screenshot pixel.
    static func resolvePointingTarget(
        _ pointingTarget: HootPointingTarget,
        capturedScreens: [CapturedScreen]
    ) -> HootResolvedPointingLocation? {
        guard !capturedScreens.isEmpty else { return nil }

        // Screens are numbered in capture order ("screen 1 of 2"). Without a
        // number the tutor means the screen the cursor is on.
        let targetScreen: CapturedScreen
        if let screenNumber = pointingTarget.screenNumber,
           capturedScreens.indices.contains(screenNumber - 1) {
            targetScreen = capturedScreens[screenNumber - 1]
        } else {
            targetScreen = capturedScreens.first(where: { $0.isCursorScreen }) ?? capturedScreens[0]
        }

        let imageWidthInPixels = Double(max(targetScreen.imageWidthInPixels, 1))
        let imageHeightInPixels = Double(max(targetScreen.imageHeightInPixels, 1))
        // Clamp so a slightly-off coordinate still lands on the right screen.
        let clampedPixelX = min(max(pointingTarget.pixelX, 0), imageWidthInPixels)
        let clampedPixelY = min(max(pointingTarget.pixelY, 0), imageHeightInPixels)

        let displayFrame = targetScreen.displayFrame
        let globalX = displayFrame.minX + (clampedPixelX / imageWidthInPixels) * displayFrame.width
        let globalY = displayFrame.maxY - (clampedPixelY / imageHeightInPixels) * displayFrame.height

        var globalBoxSize: CGSize?
        if let pixelWidth = pointingTarget.pixelWidth, let pixelHeight = pointingTarget.pixelHeight {
            globalBoxSize = CGSize(
                width: min(pixelWidth, imageWidthInPixels) / imageWidthInPixels * displayFrame.width,
                height: min(pixelHeight, imageHeightInPixels) / imageHeightInPixels * displayFrame.height
            )
        }

        return HootResolvedPointingLocation(
            globalLocation: CGPoint(x: globalX, y: globalY),
            displayFrame: displayFrame,
            globalBoxSize: globalBoxSize
        )
    }
}
