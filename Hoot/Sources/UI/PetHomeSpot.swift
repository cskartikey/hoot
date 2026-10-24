//
//  PetHomeSpot.swift
//  Hoot
//
//  Where hoot dozes. Bottom-right of the primary screen until the learner
//  drags it somewhere else; that spot is remembered across launches.
//

import AppKit

@MainActor
enum PetHomeSpot {
    private static let draggedHomeCenterDefaultsKey = "hootDraggedHomeCenter"

    /// Gap between the default corner hoot and the visible frame's right /
    /// bottom edges, so it sits just above (or beside) the Dock.
    private static let defaultInsetFromVisibleRightEdge: CGFloat = 12
    private static let defaultInsetFromVisibleBottomEdge: CGFloat = 4

    /// Kept in memory so the per-frame callers don't hit UserDefaults.
    private static var cachedDraggedHomeCenter: CGPoint? = loadDraggedHomeCenter()

    /// Center of the dozing hoot in global (AppKit, +y up) coordinates.
    static func homeCenterInGlobalSpace() -> CGPoint {
        if let cachedDraggedHomeCenter,
           let keptOnScreen = keptOnSomeScreenBelowMenuBar(cachedDraggedHomeCenter) {
            return keptOnScreen
        }
        return defaultHomeCenterInGlobalSpace()
    }

    /// While dragging only the in-memory spot moves; `persist` writes it once
    /// the drag ends.
    static func moveHome(toCenter newCenter: CGPoint, persist: Bool) {
        cachedDraggedHomeCenter = keptOnSomeScreenBelowMenuBar(newCenter) ?? newCenter
        guard persist, let cachedDraggedHomeCenter else { return }
        UserDefaults.standard.set(
            [Double(cachedDraggedHomeCenter.x), Double(cachedDraggedHomeCenter.y)],
            forKey: draggedHomeCenterDefaultsKey
        )
    }

    static func resetToDefaultCorner() {
        cachedDraggedHomeCenter = nil
        UserDefaults.standard.removeObject(forKey: draggedHomeCenterDefaultsKey)
    }

    static var hasBeenDragged: Bool { cachedDraggedHomeCenter != nil }

    /// The visible frame hoot's home is on (for placing things beside it).
    static func visibleFrameContainingHome() -> CGRect {
        let homeCenter = homeCenterInGlobalSpace()
        let screen = NSScreen.screens.first { $0.frame.contains(homeCenter) } ?? NSScreen.screens.first
        return screen?.visibleFrame ?? .zero
    }

    // MARK: - Private

    private static func defaultHomeCenterInGlobalSpace() -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return .zero }
        let visibleFrame = primaryScreen.visibleFrame
        let halfSide = PetOverlayCoordinator.fullBodySideLength / 2
        return CGPoint(
            x: visibleFrame.maxX - defaultInsetFromVisibleRightEdge - halfSide,
            y: visibleFrame.minY + defaultInsetFromVisibleBottomEdge + halfSide
        )
    }

    /// Clamps the spot so the whole body stays on the screen it's on and
    /// below the menu bar. The Dock doesn't count as a limit: hoot draws
    /// above it, and perching on the Dock is a fine place to doze. Nil when
    /// it's on no screen at all, e.g. that display was unplugged; then hoot
    /// goes back to the default corner rather than dozing off-screen.
    private static func keptOnSomeScreenBelowMenuBar(_ center: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
        let screenFrame = screen.frame
        let topBelowMenuBar = screen.visibleFrame.maxY
        let halfSide = PetOverlayCoordinator.fullBodySideLength / 2
        return CGPoint(
            x: min(max(center.x, screenFrame.minX + halfSide), screenFrame.maxX - halfSide),
            y: min(max(center.y, screenFrame.minY + halfSide), topBelowMenuBar - halfSide)
        )
    }

    private static func loadDraggedHomeCenter() -> CGPoint? {
        guard let savedCoordinates = UserDefaults.standard.array(forKey: draggedHomeCenterDefaultsKey) as? [Double],
              savedCoordinates.count == 2 else { return nil }
        return CGPoint(x: savedCoordinates[0], y: savedCoordinates[1])
    }
}
