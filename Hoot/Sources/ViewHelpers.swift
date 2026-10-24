//
//  ViewHelpers.swift
//  Hoot
//
//  Small shared helpers: hex colors and the pointing-hand cursor for
//  anything clickable.
//

import AppKit
import SwiftUI

extension Color {
    /// A color from "#RRGGBB" (the leading "#" is optional).
    init(hex hexString: String) {
        let hexDigits = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var packedRGBValue: UInt64 = 0
        Scanner(string: hexDigits).scanHexInt64(&packedRGBValue)
        self.init(
            red: Double((packedRGBValue >> 16) & 0xFF) / 255,
            green: Double((packedRGBValue >> 8) & 0xFF) / 255,
            blue: Double(packedRGBValue & 0xFF) / 255
        )
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovering, so clickable things
    /// feel clickable. Disabled controls pass `isEnabled: false`.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        onHover { isHovering in
            guard isEnabled else { return }
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
