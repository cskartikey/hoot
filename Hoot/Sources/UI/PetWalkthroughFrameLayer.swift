//
//  PetWalkthroughFrameLayer.swift
//  Hoot
//
//  Draws the walkthrough's index-card frame on one display, from the
//  stepped state `PetWalkthroughCoordinator` publishes. Its own view so it
//  observes that coordinator directly and `PetOverlayScreenView` only has
//  to place it.
//

import SwiftUI

struct PetWalkthroughFrameLayer: View {
    /// This display's frame in AppKit global coordinates.
    let screenFrame: CGRect
    @ObservedObject var walkthroughCoordinator: PetWalkthroughCoordinator
    let theme: WaitWhatTheme

    var body: some View {
        if walkthroughCoordinator.isActive,
           let frameRectInGlobalSpace = walkthroughCoordinator.frameRectInGlobalSpace,
           screenFrame.insetBy(dx: -(frameRectInGlobalSpace.width + 24), dy: -(frameRectInGlobalSpace.height + 24))
            .contains(CGPoint(x: frameRectInGlobalSpace.midX, y: frameRectInGlobalSpace.midY)) {
            // Global space has +y up: the frame's top-left is (minX, maxY).
            let frameTopLeft = PetOverlayCoordinateSpace.swiftUIPoint(
                fromGlobalPoint: CGPoint(x: frameRectInGlobalSpace.minX, y: frameRectInGlobalSpace.maxY),
                inScreenFrame: screenFrame
            )
            let isTabMirroredLeft = walkthroughCoordinator.isTabMirroredLeft
            PetPointingFrameView(
                frameSize: frameRectInGlobalSpace.size,
                label: nil,
                drawProgress: walkthroughCoordinator.drawProgress,
                tabRiseOffset: walkthroughCoordinator.tabRiseOffset,
                tabOpacity: walkthroughCoordinator.tabOpacity,
                isTabBelowFrame: walkthroughCoordinator.isTabBelowFrame,
                theme: theme,
                tone: walkthroughCoordinator.tone,
                fillLevel: walkthroughCoordinator.fillLevel,
                depthLevel: walkthroughCoordinator.depthLevel,
                isFillFlashing: walkthroughCoordinator.isFillFlashing,
                tabContent: walkthroughCoordinator.tabContent,
                isTabMirroredLeft: isTabMirroredLeft,
                tabMaximumWidthOverride: PetPointingFrameView.walkthroughTabMaximumWidth(forFrameWidth: frameRectInGlobalSpace.width)
            )
            .opacity(walkthroughCoordinator.frameOpacity)
            // The view carries transparent room for the tab above the frame
            // (and to the left when the tab is mirrored).
            .offset(
                x: frameTopLeft.x - (isTabMirroredLeft ? PetPointingFrameView.roomForTabOverhangOnLeft : 0),
                y: frameTopLeft.y - PetPointingFrameView.roomForTabAboveAndBelow
            )
        }
    }
}
