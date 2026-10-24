//
//  ScreenCapturer.swift
//  Hoot
//

import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenCapturerError: LocalizedError {
    case noDisplaysFound
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplaysFound: return "hoot couldn't find any display to look at."
        case .jpegEncodingFailed: return "hoot couldn't turn a screenshot into a JPEG."
        }
    }
}

/// Screenshots of every display with ScreenCaptureKit, excluding Hoot's own windows.
enum ScreenCapturer {
    /// Wider than this costs upload time and image tokens without helping the LLM read the screen.
    private static let maximumScreenshotWidthInPixels = 1280
    private static let jpegCompressionQuality = 0.7

    /// Returns one screenshot per display, with the display under the cursor first,
    /// because that is almost always the one the learner is asking about.
    static func captureAllScreens() async throws -> [CapturedScreen] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Hoot's own overlays (the owl, the explainer panel, bubbles) must never
        // appear in what the LLM sees, or it would describe hoot back to the learner.
        let ourProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let windowsOwnedByHoot = shareableContent.windows.filter { window in
            window.owningApplication?.processID == ourProcessIdentifier
        }

        let mouseLocationInGlobalCoordinates = NSEvent.mouseLocation
        let displaysWithScreens: [(display: SCDisplay, screen: NSScreen?)] = shareableContent.displays.map { display in
            (display, matchingAppKitScreen(forDisplayIdentifier: display.displayID))
        }
        guard !displaysWithScreens.isEmpty else { throw ScreenCapturerError.noDisplaysFound }

        let displaysOrderedCursorScreenFirst = displaysWithScreens.sorted { first, second in
            let firstContainsCursor = first.screen.map { NSMouseInRect(mouseLocationInGlobalCoordinates, $0.frame, false) } ?? false
            let secondContainsCursor = second.screen.map { NSMouseInRect(mouseLocationInGlobalCoordinates, $0.frame, false) } ?? false
            return firstContainsCursor && !secondContainsCursor
        }

        var capturedScreens: [CapturedScreen] = []
        let totalScreenCount = displaysOrderedCursorScreenFirst.count
        for (screenIndex, displayAndScreen) in displaysOrderedCursorScreenFirst.enumerated() {
            let display = displayAndScreen.display
            let displayFrameInAppKitCoordinates = displayAndScreen.screen?.frame
                ?? fallbackAppKitFrame(forDisplayIdentifier: display.displayID)
            let isCursorScreen = NSMouseInRect(mouseLocationInGlobalCoordinates, displayFrameInAppKitCoordinates, false)

            // Keep the display's aspect ratio so image pixels map linearly onto display points.
            let backingScaleFactor = displayAndScreen.screen?.backingScaleFactor ?? 2
            let nativeWidthInPixels = Int(Double(display.width) * backingScaleFactor)
            let imageWidthInPixels = min(maximumScreenshotWidthInPixels, max(1, nativeWidthInPixels))
            let imageHeightInPixels = max(1, Int((Double(imageWidthInPixels) * Double(display.height) / Double(max(1, display.width))).rounded()))

            let contentFilter = SCContentFilter(display: display, excludingWindows: windowsOwnedByHoot)
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = imageWidthInPixels
            streamConfiguration.height = imageHeightInPixels
            streamConfiguration.showsCursor = false
            streamConfiguration.scalesToFit = true

            let capturedImage = try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: streamConfiguration
            )
            let jpegImageData = try await Task.detached(priority: .userInitiated) {
                try encodeAsJPEG(capturedImage, compressionQuality: jpegCompressionQuality)
            }.value

            let positionDescription = isCursorScreen
                ? "primary focus (cursor is here)"
                : "secondary screen (cursor is not here)"
            let label = "screen \(screenIndex + 1) of \(totalScreenCount) — \(positionDescription) "
                + "(image dimensions: \(capturedImage.width)x\(capturedImage.height) pixels)"

            capturedScreens.append(CapturedScreen(
                jpegImageData: jpegImageData,
                label: label,
                imageWidthInPixels: capturedImage.width,
                imageHeightInPixels: capturedImage.height,
                displayFrame: displayFrameInAppKitCoordinates,
                isCursorScreen: isCursorScreen
            ))
        }
        return capturedScreens
    }

    private static func matchingAppKitScreen(forDisplayIdentifier displayIdentifier: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return screenNumber?.uint32Value == displayIdentifier
        }
    }

    /// CGDisplayBounds uses a top-left origin anchored to the main display;
    /// AppKit uses bottom-left, so flip y against the main display's height.
    private static func fallbackAppKitFrame(forDisplayIdentifier displayIdentifier: CGDirectDisplayID) -> CGRect {
        let quartzBounds = CGDisplayBounds(displayIdentifier)
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: quartzBounds.minX,
            y: mainDisplayHeight - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height
        )
    }

    /// Runs off the main actor: JPEG encoding a full screenshot takes long enough to hitch animations.
    nonisolated private static func encodeAsJPEG(_ image: CGImage, compressionQuality: Double) throws -> Data {
        let bitmapRepresentation = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmapRepresentation.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: compressionQuality)]
        ) else {
            throw ScreenCapturerError.jpegEncodingFailed
        }
        return jpegData
    }
}
