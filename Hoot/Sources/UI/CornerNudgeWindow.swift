//
//  CornerNudgeWindow.swift
//  Hoot
//
//  The small clickable window that holds a corner nudge bubble. The pet
//  overlay lets every click through, so the bubble needs its own window:
//  a borderless, non-activating panel one level above the overlay (and the
//  corner hoot's click target), on every Space, that never takes focus.
//
//  It sits above and to the left of the dozing corner hoot, right edges
//  lined up like the design's mock. When the corner hoot is hidden ("hide
//  corner hoot", the explainer playing) it anchors to the bottom-right of
//  the primary screen's visible frame instead.
//

import AppKit
import SwiftUI

@MainActor
final class CornerNudgePresenter {
    static let shared = CornerNudgePresenter()

    /// Room around the bubble for its shadow, so the shadow isn't clipped
    /// by the window's edges.
    static let shadowMarginAroundBubble: CGFloat = 18
    /// Gap between the bubble's bottom edge and the top of the corner hoot.
    private static let gapAboveCornerHoot: CGFloat = 4
    /// Inset from the visible frame's corner when there's no hoot to sit by.
    private static let insetFromVisibleCornerWithoutHoot: CGFloat = 12

    private var nudgePanel: CornerNudgePanel?
    private var presentedNudgeId: UUID?
    private var repositionTimer: Timer?

    func present(_ nudge: HootNudge) {
        let nudgePanel = nudgePanel ?? CornerNudgePanel()
        self.nudgePanel = nudgePanel
        presentedNudgeId = nudge.id

        let hostingView = CornerNudgeHostingView(rootView: CornerNudgeBubbleView(nudge: nudge))
        // The panel's frame is set from the measured size below; SwiftUI
        // must never resize the window on its own (sync resizes crash).
        hostingView.sizingOptions = []
        let fittingSize = hostingView.fittingSize
        hostingView.frame = CGRect(origin: .zero, size: fittingSize)
        nudgePanel.contentView = hostingView
        nudgePanel.appearance = WaitWhatThemeStore.shared.nsAppearance
        nudgePanel.alphaValue = 1
        nudgePanel.setFrame(panelFrame(forContentSize: fittingSize), display: false)
        nudgePanel.orderFrontRegardless()

        repositionTimer?.invalidate()
        // Follows the corner hoot being hidden/shown and the Dock moving.
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepPanelAnchored() }
        }
    }

    /// Fades the bubble out. Ignores stale calls for a nudge already replaced.
    func dismiss(nudgeId: UUID) {
        guard presentedNudgeId == nudgeId, let nudgePanel else { return }
        presentedNudgeId = nil
        repositionTimer?.invalidate()
        repositionTimer = nil
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.2
            nudgePanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new nudge may have been presented during the fade.
                guard let self, self.presentedNudgeId == nil else { return }
                self.nudgePanel?.orderOut(nil)
                self.nudgePanel?.contentView = nil
            }
        }
    }

    private func keepPanelAnchored() {
        guard let nudgePanel, presentedNudgeId != nil else { return }
        let anchoredFrame = panelFrame(forContentSize: nudgePanel.frame.size)
        if anchoredFrame != nudgePanel.frame {
            nudgePanel.setFrame(anchoredFrame, display: true)
        }
    }

    /// `contentSize` already includes the shadow margin (it's the hosting
    /// view's fitting size), so the bubble's own edges are inset by it.
    private func panelFrame(forContentSize contentSize: CGSize) -> CGRect {
        let margin = Self.shadowMarginAroundBubble
        guard PetOverlayManager.isCornerHootDozingOnScreen else {
            let visibleFrame = NSScreen.screens.first?.visibleFrame ?? .zero
            return CGRect(
                x: (visibleFrame.maxX - Self.insetFromVisibleCornerWithoutHoot + margin - contentSize.width).rounded(),
                y: (visibleFrame.minY + Self.insetFromVisibleCornerWithoutHoot - margin).rounded(),
                width: contentSize.width,
                height: contentSize.height
            )
        }

        // hoot can be dragged anywhere, so the bubble goes above it unless
        // that would run off the top, and lines up with whichever side of
        // hoot leaves it on screen.
        let homeCenter = PetOverlayCoordinator.homeCenterInGlobalSpace()
        let hootHalfSide = PetOverlayCoordinator.fullBodySideLength / 2
        let visibleFrame = PetHomeSpot.visibleFrameContainingHome()

        let bubbleBottomEdgeAboveHoot = homeCenter.y + hootHalfSide + Self.gapAboveCornerHoot
        let fitsAboveHoot = bubbleBottomEdgeAboveHoot - margin + contentSize.height <= visibleFrame.maxY
        let panelOriginY = fitsAboveHoot
            ? bubbleBottomEdgeAboveHoot - margin
            : homeCenter.y - hootHalfSide - Self.gapAboveCornerHoot + margin - contentSize.height

        // Right-aligned with hoot by default (hoot in the right half);
        // left-aligned when hoot sits in the left half of the screen.
        let isHootInLeftHalf = homeCenter.x < visibleFrame.midX
        var panelOriginX = isHootInLeftHalf
            ? homeCenter.x - hootHalfSide - margin
            : homeCenter.x + hootHalfSide + margin - contentSize.width
        panelOriginX = min(max(panelOriginX, visibleFrame.minX - margin), visibleFrame.maxX + margin - contentSize.width)

        return CGRect(
            x: panelOriginX.rounded(),
            y: panelOriginY.rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

/// Borderless, non-activating, on every Space (fullscreen ones too), one
/// level above the corner hoot's click target. Never key or main, so
/// clicking a button doesn't pull focus from what the learner is doing.
private final class CornerNudgePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons answer the very first click even though the panel never
/// becomes key.
private final class CornerNudgeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
