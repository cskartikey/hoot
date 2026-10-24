//
//  PetOverlaySupport.swift
//  Hoot
//
//  Small, stateless helpers for the pet overlay:
//    - turning the streamed answer into what the bubble should show
//    - converting between AppKit global coordinates and one screen's
//      SwiftUI coordinates
//    - placing bubbles / chips beside the cursor head without leaving the screen
//    - asking the window server whether a fullscreen app is in front
//

import AppKit
import SwiftUI

// MARK: - Answer text for the bubble

enum PetOverlayAnswerText {
    /// The LLM's text can carry `[VIDEO:…]` and `[POINT:…]` tags meant for the
    /// app, not the learner. This removes complete VIDEO tags, cuts everything
    /// from a POINT tag on (it is always the last thing in the answer), and
    /// hides a tag that is still half-way through streaming in (e.g. "…[PO").
    static func displayableText(fromStreamedResponseText streamedResponseText: String) -> String {
        var remainingText = streamedResponseText

        while let videoTagOpeningRange = remainingText.range(of: "[VIDEO:"),
              let videoTagClosingRange = remainingText.range(
                of: "]",
                range: videoTagOpeningRange.upperBound..<remainingText.endIndex
              ) {
            remainingText.removeSubrange(videoTagOpeningRange.lowerBound..<videoTagClosingRange.upperBound)
        }

        // A POINT tag, or a VIDEO tag whose "]" has not arrived yet, hides the rest.
        for tagOpening in ["[POINT:", "[VIDEO:"] {
            if let tagOpeningRange = remainingText.range(of: tagOpening) {
                remainingText = String(remainingText[..<tagOpeningRange.lowerBound])
            }
        }

        // A partial tag at the very end, like "[" or "[POIN".
        if let lastOpeningBracketIndex = remainingText.lastIndex(of: "[") {
            let textAfterBracket = remainingText[remainingText.index(after: lastOpeningBracketIndex)...]
            let isStillStreamingATag = textAfterBracket.allSatisfy { $0.isUppercase || $0 == ":" }
            if isStillStreamingATag {
                remainingText = String(remainingText[..<lastOpeningBracketIndex])
            }
        }

        return remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Coordinates

/// The overlay keeps every position in AppKit global coordinates (points,
/// bottom-left origin of the primary screen) so hoot can fly across
/// monitors. Each screen's SwiftUI view converts to its own top-left space.
enum PetOverlayCoordinateSpace {
    static func swiftUIPoint(fromGlobalPoint globalPoint: CGPoint, inScreenFrame screenFrame: CGRect) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.minX, y: screenFrame.maxY - globalPoint.y)
    }

    /// The screen whose frame contains `globalPoint`, falling back to the
    /// nearest one so a point a hair off the edge still has a home.
    static func screenFrame(containingGlobalPoint globalPoint: CGPoint) -> CGRect? {
        let allScreenFrames = NSScreen.screens.map(\.frame)
        if let containingScreenFrame = allScreenFrames.first(where: { $0.contains(globalPoint) }) {
            return containingScreenFrame
        }
        return allScreenFrames.min { firstFrame, secondFrame in
            distanceSquared(from: globalPoint, to: firstFrame) < distanceSquared(from: globalPoint, to: secondFrame)
        }
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontalDistance = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let verticalDistance = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }
}

// MARK: - Placement beside the head (SwiftUI coordinates of one screen)

enum PetOverlayPlacement {
    static let screenEdgeMargin: CGFloat = 8

    /// Center for a bubble hanging under the head: its left edge 2pt left of
    /// the head, 8pt below it. Flips above the head near the bottom of the
    /// screen and is clamped so it never leaves the screen.
    static func centerForBubbleBelowHead(headFrame: CGRect, bubbleSize: CGSize, screenSize: CGSize) -> CGPoint {
        let gapBetweenHeadAndBubble: CGFloat = 8
        let bubbleLeftEdge = clamp(
            headFrame.minX - 2,
            lowerBound: screenEdgeMargin,
            upperBound: screenSize.width - screenEdgeMargin - bubbleSize.width
        )

        var bubbleTopEdge = headFrame.maxY + gapBetweenHeadAndBubble
        if bubbleTopEdge + bubbleSize.height > screenSize.height - screenEdgeMargin {
            bubbleTopEdge = headFrame.minY - gapBetweenHeadAndBubble - bubbleSize.height
        }
        bubbleTopEdge = clamp(
            bubbleTopEdge,
            lowerBound: screenEdgeMargin,
            upperBound: screenSize.height - screenEdgeMargin - bubbleSize.height
        )

        return CGPoint(x: bubbleLeftEdge + bubbleSize.width / 2, y: bubbleTopEdge + bubbleSize.height / 2)
    }

    /// Center for a small piece beside the head (bars, chip, countdown). Uses
    /// the preferred side unless it would leave the screen, then clamps.
    /// Vertically centered on the head unless `topOffsetFromHeadTop` is given.
    static func centerForPieceBesideHead(
        headFrame: CGRect,
        pieceSize: CGSize,
        screenSize: CGSize,
        horizontalGapFromHead: CGFloat,
        topOffsetFromHeadTop: CGFloat? = nil,
        prefersRightSideOfHead: Bool = true
    ) -> CGPoint {
        let leftEdgeWhenOnRightSide = headFrame.maxX + horizontalGapFromHead
        let leftEdgeWhenOnLeftSide = headFrame.minX - horizontalGapFromHead - pieceSize.width
        let fitsOnRightSide = leftEdgeWhenOnRightSide + pieceSize.width <= screenSize.width - screenEdgeMargin
        let fitsOnLeftSide = leftEdgeWhenOnLeftSide >= screenEdgeMargin

        let usesRightSide = prefersRightSideOfHead
            ? (fitsOnRightSide || !fitsOnLeftSide)
            : !(fitsOnLeftSide || !fitsOnRightSide)
        let pieceLeftEdge = clamp(
            usesRightSide ? leftEdgeWhenOnRightSide : leftEdgeWhenOnLeftSide,
            lowerBound: screenEdgeMargin,
            upperBound: screenSize.width - screenEdgeMargin - pieceSize.width
        )

        let unclampedTopEdge = topOffsetFromHeadTop.map { headFrame.minY + $0 }
            ?? (headFrame.midY - pieceSize.height / 2)
        let pieceTopEdge = clamp(
            unclampedTopEdge,
            lowerBound: screenEdgeMargin,
            upperBound: screenSize.height - screenEdgeMargin - pieceSize.height
        )

        return CGPoint(x: pieceLeftEdge + pieceSize.width / 2, y: pieceTopEdge + pieceSize.height / 2)
    }

    /// Like `min(max(...))`, but tolerates an upper bound below the lower one
    /// (a piece wider than the screen) by preferring the lower bound.
    private static func clamp(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        max(lowerBound, min(value, max(upperBound, lowerBound)))
    }
}

// MARK: - Fullscreen detection

enum FullscreenAppDetector {
    /// True when the frontmost app (not hoot) has a normal-level window that
    /// covers the whole of `screenFrame`, which is what a fullscreen app or
    /// fullscreen video looks like to the window server.
    static func isFrontmostApplicationFullscreen(onScreenFrame screenFrame: CGRect) -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowDescriptions = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        // The window server uses a top-left origin anchored to the primary screen.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let screenFrameInWindowServerSpace = CGRect(
            x: screenFrame.minX,
            y: primaryScreenHeight - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )

        return windowDescriptions.contains { windowDescription in
            guard let ownerProcessIdentifier = windowDescription[kCGWindowOwnerPID as String] as? Int,
                  ownerProcessIdentifier == Int(frontmostApplication.processIdentifier),
                  let windowLayer = windowDescription[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let windowBoundsDictionary = windowDescription[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: windowBoundsDictionary as CFDictionary) else {
                return false
            }
            return abs(windowBounds.minX - screenFrameInWindowServerSpace.minX) < 1
                && abs(windowBounds.minY - screenFrameInWindowServerSpace.minY) < 1
                && abs(windowBounds.width - screenFrameInWindowServerSpace.width) < 1
                && abs(windowBounds.height - screenFrameInWindowServerSpace.height) < 1
        }
    }
}
