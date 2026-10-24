//
//  HootResponseTags.swift
//  Hoot
//
//  Pulls the machine-readable tags out of the tutor's answer:
//    [VIDEO:brief]                 → ask the studio for an explainer video
//    [POINT:x,y:label(:screenN)]   → hop over and point at something
//    [POINT:none]                  → nothing to point at
//  and maps a point from screenshot pixels to AppKit global coordinates.
//

import AppKit
import Foundation

/// A place the tutor asked hoot to point at, still in screenshot pixel space.
struct HootPointingTarget: Equatable {
    let pixelX: Double
    let pixelY: Double
    let label: String?
    /// 1-based screen number from the image label, when the tutor gave one.
    let screenNumber: Int?
}

/// A pointing target resolved to a real place on the user's displays.
struct HootResolvedPointingLocation: Equatable {
    /// AppKit global coordinates (points, bottom-left origin).
    let globalLocation: CGPoint
    let displayFrame: CGRect
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

    /// Reads the last [POINT:...] tag in the response. Returns nil for
    /// [POINT:none], a missing tag, or a tag we can't make sense of — in all
    /// of those cases hoot simply doesn't point.
    static func parsePointingTarget(from responseText: String) -> HootPointingTarget? {
        // Accepts decimals and stray spaces ("[POINT: 640 , 380 : the grid ]")
        // because models aren't perfectly consistent about the format.
        let pattern = #"\[POINT:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::([^\]]*))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let wholeRange = NSRange(responseText.startIndex..., in: responseText)
        guard let lastMatch = regex.matches(in: responseText, range: wholeRange).last,
              let xRange = Range(lastMatch.range(at: 1), in: responseText),
              let yRange = Range(lastMatch.range(at: 2), in: responseText),
              let pixelX = Double(responseText[xRange]),
              let pixelY = Double(responseText[yRange]) else {
            return nil
        }

        // The part after the coordinates is "label" or "label:screenN".
        var label: String?
        var screenNumber: Int?
        if let labelAndScreenRange = Range(lastMatch.range(at: 3), in: responseText) {
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

        return HootPointingTarget(pixelX: pixelX, pixelY: pixelY, label: label, screenNumber: screenNumber)
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

        return HootResolvedPointingLocation(
            globalLocation: CGPoint(x: globalX, y: globalY),
            displayFrame: displayFrame
        )
    }
}
