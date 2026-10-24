//
//  CapturedScreen.swift
//  Hoot
//

import CoreGraphics
import Foundation

/// One display's screenshot, as sent to the LLM.
struct CapturedScreen {
    let jpegImageData: Data
    /// e.g. "screen 1 of 2 — primary focus (cursor is here) (image dimensions: 1280x800 pixels)".
    /// The dimensions matter: the LLM answers [POINT:x,y] in this image's pixel space,
    /// and the app maps those pixels back onto `displayFrame`.
    let label: String
    let imageWidthInPixels: Int
    let imageHeightInPixels: Int
    /// The display's frame in AppKit global coordinates (points, bottom-left origin).
    let displayFrame: CGRect
    let isCursorScreen: Bool
}
