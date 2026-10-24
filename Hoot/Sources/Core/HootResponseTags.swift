//
//  HootResponseTags.swift
//  Hoot
//
//  Pulls the machine-readable tags out of the tutor's answer:
//    [SKETCH:brief]                → ask the LLM for a quick animated sketch
//    [VIDEO:brief]                 → ask the studio for an explainer video
//    [POINT:x,y,w,h:label(:screenN)] → box the thing (top-left x,y + size)
//    [POINT:x,y:label(:screenN)]   → older point form (center only)
//    [POINT:none]                  → nothing to point at
//    [CONCEPT:words]               → what to remember this question under
//    [CONCEPT:none]                → chit-chat, don't remember
//    [REVIEW:remembered|shaky|forgot] → the grade of a spaced-review answer
//    [DRAW:arrow:x1,y1,x2,y2(:screenN)]  → marks drawn over the pointed thing
//    [DRAW:circle:x,y,w,h(:screenN)]       (after the point tag, up to six,
//    [DRAW:underline:x,y,w(:screenN)]       revealed one by one while hoot
//    [DRAW:label:x,y:text(:screenN)]        talks)
//  None of them is ever spoken: speech stops at the first "[".
//  Also maps points from screenshot pixels to AppKit global coordinates.
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

/// One mark the tutor asked hoot to draw, still in screenshot pixel space
/// (top-left origin, the same space as the point tag).
enum HootAnnotation: Equatable {
    case arrow(fromX: Double, fromY: Double, toX: Double, toY: Double, screenNumber: Int?)
    case circle(x: Double, y: Double, width: Double, height: Double, screenNumber: Int?)
    case underline(x: Double, y: Double, width: Double, screenNumber: Int?)
    case label(x: Double, y: Double, text: String, screenNumber: Int?)

    /// The tutor may send at most this many marks; anything past it is dropped.
    static let maximumCountPerReply = 6

    var screenNumber: Int? {
        switch self {
        case let .arrow(_, _, _, _, screenNumber), let .circle(_, _, _, _, screenNumber),
             let .underline(_, _, _, screenNumber), let .label(_, _, _, screenNumber):
            return screenNumber
        }
    }
}

/// A mark resolved to AppKit global coordinates (points, bottom-left origin),
/// tied to the display it belongs on so each overlay window draws only its own.
struct HootResolvedAnnotation: Equatable, Identifiable {
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        /// The box the ring loops around, in global coordinates.
        case ring(CGRect)
        /// The line's left end and its length in points.
        case underline(start: CGPoint, width: CGFloat)
        /// The chip's top-left corner (its top edge is at `topLeft.y`).
        case label(topLeft: CGPoint, text: String)
    }

    /// Position in the reply: marks are revealed in this order.
    let id: Int
    let shape: Shape
    let displayFrame: CGRect
}

/// The pixel space of one captured screenshot and how it maps onto the
/// display it was taken from. Screenshots have a top-left origin with y going
/// down; AppKit has a bottom-left origin with y going up, so y is flipped
/// against the display's maxY. Screenshots may also be downscaled, so pixels
/// are scaled by display points per screenshot pixel. Shared by pointing and
/// drawing so both land in the same place.
struct HootScreenshotPixelSpace {
    let displayFrame: CGRect
    let imageWidthInPixels: Double
    let imageHeightInPixels: Double

    /// Screens are numbered in capture order ("screen 1 of 2"). Without a
    /// number the tutor means the screen the cursor is on.
    init?(screenNumber: Int?, capturedScreens: [CapturedScreen]) {
        guard !capturedScreens.isEmpty else { return nil }
        let targetScreen: CapturedScreen
        if let screenNumber, capturedScreens.indices.contains(screenNumber - 1) {
            targetScreen = capturedScreens[screenNumber - 1]
        } else {
            targetScreen = capturedScreens.first(where: { $0.isCursorScreen }) ?? capturedScreens[0]
        }
        displayFrame = targetScreen.displayFrame
        imageWidthInPixels = Double(max(targetScreen.imageWidthInPixels, 1))
        imageHeightInPixels = Double(max(targetScreen.imageHeightInPixels, 1))
    }

    /// Clamps so a slightly-off coordinate still lands on the right screen.
    func globalPoint(fromPixelX pixelX: Double, pixelY: Double) -> CGPoint {
        let clampedPixelX = min(max(pixelX, 0), imageWidthInPixels)
        let clampedPixelY = min(max(pixelY, 0), imageHeightInPixels)
        return CGPoint(
            x: displayFrame.minX + (clampedPixelX / imageWidthInPixels) * displayFrame.width,
            y: displayFrame.maxY - (clampedPixelY / imageHeightInPixels) * displayFrame.height
        )
    }

    func globalSize(fromPixelWidth pixelWidth: Double, pixelHeight: Double) -> CGSize {
        CGSize(
            width: min(max(pixelWidth, 0), imageWidthInPixels) / imageWidthInPixels * displayFrame.width,
            height: min(max(pixelHeight, 0), imageHeightInPixels) / imageHeightInPixels * displayFrame.height
        )
    }
}

enum HootResponseTags {

    /// Only the text before the first "[" is ever spoken. Tags always come at
    /// the end, so this is the same rule the streaming speech uses, which keeps
    /// the "already enqueued" character count valid against the final text.
    static func speakableText(from responseText: String) -> String {
        if let firstTagStart = responseText.firstIndex(of: "[") {
            return String(responseText[..<firstTagStart])
        }
        return responseText
    }

    /// Finds a [VIDEO:brief] tag anywhere in the response and removes it,
    /// so the brief is never spoken aloud.
    static func parseExplainerVideoRequest(from responseText: String) -> (textWithoutVideoTag: String, explainerVideoBrief: String?) {
        let parseResult = removeFirstBriefTag(named: "VIDEO", from: responseText)
        return (parseResult.textWithoutTag, parseResult.brief)
    }

    /// Finds a [SKETCH:brief] tag (the quick animated-SVG path) and removes
    /// it, the same way as the video tag.
    static func parseSketchRequest(from responseText: String) -> (textWithoutSketchTag: String, sketchBrief: String?) {
        let parseResult = removeFirstBriefTag(named: "SKETCH", from: responseText)
        return (parseResult.textWithoutTag, parseResult.brief)
    }

    /// Shared by the video and sketch parsers: the first [NAME:brief] tag,
    /// cut out of the text, with its brief trimmed. Case-insensitive on NAME
    /// because models occasionally lowercase a tag.
    private static func removeFirstBriefTag(named tagName: String, from responseText: String) -> (textWithoutTag: String, brief: String?) {
        let pattern = #"\["# + tagName + #"\s*:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let briefRange = Range(match.range(at: 1), in: responseText),
              let fullTagRange = Range(match.range, in: responseText) else {
            return (responseText, nil)
        }
        let brief = String(responseText[briefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var textWithoutTag = responseText
        textWithoutTag.removeSubrange(fullTagRange)
        return (textWithoutTag, brief.isEmpty ? nil : brief)
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
    /// coordinates (see `HootScreenshotPixelSpace` for the flip and scale).
    static func resolvePointingTarget(
        _ pointingTarget: HootPointingTarget,
        capturedScreens: [CapturedScreen]
    ) -> HootResolvedPointingLocation? {
        guard let pixelSpace = HootScreenshotPixelSpace(screenNumber: pointingTarget.screenNumber, capturedScreens: capturedScreens) else {
            return nil
        }
        var globalBoxSize: CGSize?
        if let pixelWidth = pointingTarget.pixelWidth, let pixelHeight = pointingTarget.pixelHeight {
            globalBoxSize = pixelSpace.globalSize(fromPixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        return HootResolvedPointingLocation(
            globalLocation: pixelSpace.globalPoint(fromPixelX: pointingTarget.pixelX, pixelY: pointingTarget.pixelY),
            displayFrame: pixelSpace.displayFrame,
            globalBoxSize: globalBoxSize
        )
    }

    // MARK: - Drawing

    /// Every [DRAW:kind:...] tag in the response, in order, capped at
    /// `HootAnnotation.maximumCountPerReply`. A tag that can't be made sense
    /// of (wrong number count, zero size, empty label) is skipped rather than
    /// failing the whole set, so one bad mark never hides the good ones.
    static func parseAnnotations(from responseText: String) -> [HootAnnotation] {
        let pattern = #"\[DRAW\s*:\s*(arrow|circle|underline|label)\s*:\s*([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)

        var annotations: [HootAnnotation] = []
        for match in regex.matches(in: responseText, range: wholeRange) {
            guard annotations.count < HootAnnotation.maximumCountPerReply,
                  let kindRange = Range(match.range(at: 1), in: responseText),
                  let bodyRange = Range(match.range(at: 2), in: responseText) else { continue }
            let kind = responseText[kindRange].lowercased()
            let body = String(responseText[bodyRange])

            // The body is "numbers" or "numbers:text" or either followed by
            // ":screenN". The first component is always the numbers.
            var components = body
                .split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let numbersComponent = components.first else { continue }
            components.removeFirst()
            var screenNumber: Int?
            if let lastComponent = components.last, let parsedScreenNumber = screenNumberFromComponent(lastComponent) {
                screenNumber = parsedScreenNumber
                components.removeLast()
            }
            let textAfterNumbers = components.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

            // Decimals and stray spaces are fine ("640 , 380.5").
            let numbers = numbersComponent
                .split(separator: ",", omittingEmptySubsequences: false)
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

            switch kind {
            case "arrow":
                guard numbers.count == 4 else { continue }
                annotations.append(.arrow(fromX: numbers[0], fromY: numbers[1], toX: numbers[2], toY: numbers[3], screenNumber: screenNumber))
            case "circle":
                guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { continue }
                annotations.append(.circle(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3], screenNumber: screenNumber))
            case "underline":
                guard numbers.count == 3, numbers[2] > 0 else { continue }
                annotations.append(.underline(x: numbers[0], y: numbers[1], width: numbers[2], screenNumber: screenNumber))
            case "label":
                guard numbers.count == 2, !textAfterNumbers.isEmpty, textAfterNumbers.count <= 40 else { continue }
                annotations.append(.label(x: numbers[0], y: numbers[1], text: textAfterNumbers, screenNumber: screenNumber))
            default:
                continue
            }
        }
        return annotations
    }

    /// Maps the marks to global coordinates with the same math as the point
    /// tag, so a ring lands exactly where the frame would. Marks whose
    /// screen can't be found are dropped.
    static func resolveAnnotations(
        _ annotations: [HootAnnotation],
        capturedScreens: [CapturedScreen]
    ) -> [HootResolvedAnnotation] {
        var resolvedAnnotations: [HootResolvedAnnotation] = []
        for (annotationIndex, annotation) in annotations.enumerated() {
            guard let pixelSpace = HootScreenshotPixelSpace(screenNumber: annotation.screenNumber, capturedScreens: capturedScreens) else { continue }
            let shape: HootResolvedAnnotation.Shape
            switch annotation {
            case let .arrow(fromX, fromY, toX, toY, _):
                shape = .arrow(
                    from: pixelSpace.globalPoint(fromPixelX: fromX, pixelY: fromY),
                    to: pixelSpace.globalPoint(fromPixelX: toX, pixelY: toY)
                )
            case let .circle(x, y, width, height, _):
                // Global rects grow upward, so the box's origin is its
                // bottom-left: the screenshot's bottom edge (y + height).
                let bottomLeft = pixelSpace.globalPoint(fromPixelX: x, pixelY: y + height)
                let size = pixelSpace.globalSize(fromPixelWidth: width, pixelHeight: height)
                shape = .ring(CGRect(origin: bottomLeft, size: size))
            case let .underline(x, y, width, _):
                shape = .underline(
                    start: pixelSpace.globalPoint(fromPixelX: x, pixelY: y),
                    width: pixelSpace.globalSize(fromPixelWidth: width, pixelHeight: 0).width
                )
            case let .label(x, y, text, _):
                shape = .label(topLeft: pixelSpace.globalPoint(fromPixelX: x, pixelY: y), text: text)
            }
            resolvedAnnotations.append(HootResolvedAnnotation(id: annotationIndex, shape: shape, displayFrame: pixelSpace.displayFrame))
        }
        return resolvedAnnotations
    }
}
