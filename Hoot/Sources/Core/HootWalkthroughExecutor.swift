//
//  HootWalkthroughExecutor.swift
//  Hoot
//
//  "Just do it" (docs/design/WALKTHROUGH.md, "Just do it"): when the learner
//  explicitly asks hoot to do the steps for them, hoot performs the
//  walkthrough's clicks itself instead of only pointing. This file is the
//  hands: it moves the real cursor to a step's box in a few visible hops
//  (so the learner sees it travel, like hoot flying there), posts one left
//  click, waits for the UI to settle, and watches for the reasons to stop.
//
//  Clicks only. No typing, no drags, no keyboard shortcuts, no right-clicks:
//  the worst a stray click can do is open the wrong menu, which the learner
//  can undo by hand. The explicit phrase in the question is the only
//  authorization; the controller never starts this without it.
//
//  Posting mouse events needs Accessibility (the key monitor's listen-only
//  tap also works with Input Monitoring, which is not enough here), so the
//  controller checks `canPostMouseEvents` before promising to click.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Why an execution stopped before (or instead of) finishing every step.
enum HootWalkthroughExecutionStop: Equatable {
    /// The learner moved the mouse themselves while hoot was clicking.
    case learnerMovedTheMouse
    /// A fresh look at the screen couldn't find the step's control.
    case controlNotFound(label: String?)
    /// The step's box resolved to a point on no display.
    case targetOffEveryScreen
    /// An explainer panel is open; hoot never clicks around it.
    case explainerPanelIsOpen
    /// Accessibility isn't granted, so CGEvent posting would be silently dropped.
    case accessibilityNotGranted
    /// A new ⌃⌥ hold or a newer answer took over.
    case cancelled

    /// One short sentence hoot says when it stops early (nothing for a cancel:
    /// the new hold has already cut in).
    var spokenSentence: String? {
        switch self {
        case .learnerMovedTheMouse:
            return "you've got the mouse, so i'll stop here. your turn."
        case .controlNotFound(let label):
            if let label, !label.isEmpty { return "i can't find \(label) now, your turn." }
            return "i can't find the next button, your turn."
        case .targetOffEveryScreen:
            return "that one's off the screen, so i'll stop here. your turn."
        case .explainerPanelIsOpen:
            return "i won't click while the explainer is open. close it and ask again."
        case .accessibilityNotGranted:
            return "i can't click for you yet. turn on accessibility in my menu bar panel, then ask again."
        case .cancelled:
            return nil
        }
    }
}

/// Moves the cursor and clicks for one walkthrough. One instance per
/// execution; the controller owns it alongside the walkthrough runner.
@MainActor
final class HootWalkthroughExecutor {
    /// Never more than this many clicks per request, whatever the tutor returned.
    static let maximumStepCount = 5
    /// The cursor's trip to a box: a few visible hops over about a quarter second.
    static let cursorTravelDurationInSeconds: TimeInterval = 0.25
    static let cursorTravelHopCount = 10
    /// Between mouse down and mouse up, so the target app sees a real press.
    static let secondsBetweenMouseDownAndUp: TimeInterval = 0.04
    /// After a click, how long the UI gets to open its menu or dialog.
    static let secondsToLetTheInterfaceSettle: TimeInterval = 0.7
    /// Beyond this distance from where hoot last put it, the cursor counts as the learner's.
    static let learnerMouseMoveToleranceInPoints: CGFloat = 12

    /// Where hoot last placed the cursor (AppKit global coordinates), the
    /// reference for "did the learner move it". nil before the first move.
    private(set) var lastPlacedCursorLocation: CGPoint?

    /// Posting synthetic mouse events needs the Accessibility grant; without
    /// it the events are dropped without any error.
    static var canPostMouseEvents: Bool {
        AXIsProcessTrusted()
    }

    /// True when `globalPoint` lies on some display.
    static func isOnAnyScreen(_ globalPoint: CGPoint) -> Bool {
        NSScreen.screens.contains { NSMouseInRect(globalPoint, $0.frame, false) }
    }

    /// Starts tracking from wherever the cursor is right now, so a learner
    /// nudge during the first sentence counts as theirs too.
    func noteCursorAsPlacedByHootNow() {
        lastPlacedCursorLocation = NSEvent.mouseLocation
    }

    /// True once the cursor has drifted from where hoot last put it by more
    /// than the tolerance. Before the first placement nothing counts.
    var learnerHasMovedTheMouse: Bool {
        guard let lastPlacedCursorLocation else { return false }
        let currentLocation = NSEvent.mouseLocation
        return hypot(currentLocation.x - lastPlacedCursorLocation.x, currentLocation.y - lastPlacedCursorLocation.y)
            > Self.learnerMouseMoveToleranceInPoints
    }

    /// Moves the cursor to `globalPoint` in hops, clicks once, and lets the
    /// UI settle. Returns nil on success, or the reason it stopped. The
    /// learner's own mouse movement is checked between hops, so a grab of
    /// the mouse mid-flight stops everything before the click lands.
    func moveCursorAndClick(
        at globalPoint: CGPoint,
        label: String?,
        isCancelled: () -> Bool
    ) async -> HootWalkthroughExecutionStop? {
        guard Self.canPostMouseEvents else { return .accessibilityNotGranted }
        guard Self.isOnAnyScreen(globalPoint) else { return .targetOffEveryScreen }
        if learnerHasMovedTheMouse { return .learnerMovedTheMouse }

        let startLocation = lastPlacedCursorLocation ?? NSEvent.mouseLocation
        let hopInterval = Self.cursorTravelDurationInSeconds / Double(Self.cursorTravelHopCount)
        for hopIndex in 1...Self.cursorTravelHopCount {
            if isCancelled() { return .cancelled }
            // Ease out: big hops first, small settles, like the frame slide.
            let linearFraction = Double(hopIndex) / Double(Self.cursorTravelHopCount)
            let easedFraction = 1 - pow(1 - linearFraction, 2)
            let hopLocation = CGPoint(
                x: startLocation.x + (globalPoint.x - startLocation.x) * easedFraction,
                y: startLocation.y + (globalPoint.y - startLocation.y) * easedFraction
            )
            postMouseMoved(to: hopLocation)
            lastPlacedCursorLocation = hopLocation
            try? await Task.sleep(nanoseconds: UInt64(hopInterval * 1_000_000_000))
            if learnerHasMovedTheMouse { return .learnerMovedTheMouse }
        }
        if isCancelled() { return .cancelled }

        postLeftClick(at: globalPoint)
        lastPlacedCursorLocation = globalPoint
        print("🖱️ clicked \(label ?? "(no label)") at (\(Int(globalPoint.x)), \(Int(globalPoint.y)))")
        HootDemoLog.recordEvent("click", label ?? "")

        try? await Task.sleep(nanoseconds: UInt64(Self.secondsToLetTheInterfaceSettle * 1_000_000_000))
        if isCancelled() { return .cancelled }
        return nil
    }

    // MARK: - CGEvent posting

    /// AppKit global coordinates have their origin at the bottom-left of
    /// the main display; CGEvent wants the top-left (y down). Flip against
    /// the main display's height.
    private static func quartzPoint(fromAppKitGlobalPoint appKitPoint: CGPoint) -> CGPoint {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: appKitPoint.x, y: mainDisplayHeight - appKitPoint.y)
    }

    private func postMouseMoved(to appKitPoint: CGPoint) {
        let quartzPoint = Self.quartzPoint(fromAppKitGlobalPoint: appKitPoint)
        guard let mouseMovedEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else { return }
        mouseMovedEvent.post(tap: .cghidEventTap)
    }

    private func postLeftClick(at appKitPoint: CGPoint) {
        let quartzPoint = Self.quartzPoint(fromAppKitGlobalPoint: appKitPoint)
        guard let mouseDownEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ), let mouseUpEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else { return }
        // A click count of 1 so the target never reads it as part of a double-click.
        mouseDownEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUpEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDownEvent.post(tap: .cghidEventTap)
        // The up event is posted after a short, blocking pause: an immediate
        // up can be coalesced away by some apps, and 40ms is not noticeable.
        usleep(useconds_t(Self.secondsBetweenMouseDownAndUp * 1_000_000))
        mouseUpEvent.post(tap: .cghidEventTap)
    }
}
