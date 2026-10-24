//
//  ExplainerPlaytimeView.swift
//  Hoot
//
//  What the explainer panel shows while the studio renders a video: the
//  selected buddy and a friend tossing a pixel ball back and forth, so the
//  30–60s wait feels like part of the show instead of a loading screen.
//

import SwiftUI

struct ExplainerPlaytimeView: View {
    let theme: WaitWhatTheme

    @ObservedObject private var themeStore = WaitWhatThemeStore.shared

    /// One throw takes this long; the ball goes left → right, then back.
    private let secondsPerThrow: Double = 1.3
    private let petSideLength: CGFloat = 48
    private let petInsetFromSides: CGFloat = 34
    private let groundInsetFromBottom: CGFloat = 26
    private let ballSideLength: CGFloat = 6
    private let throwArcHeight: CGFloat = 58

    /// The selected buddy plays on the left; a different mascot visits on the right.
    private var leftPlaymateMascot: WaitWhatMascot { themeStore.mascot }
    private var rightPlaymateMascot: WaitWhatMascot {
        themeStore.mascot == .lotl ? .hoot : .lotl
    }

    var body: some View {
        GeometryReader { geometryProxy in
            let playAreaSize = geometryProxy.size
            TimelineView(.animation) { timelineContext in
                let throwMoment = currentThrowMoment(at: timelineContext.date)
                ZStack(alignment: .topLeading) {
                    groundLine(playAreaSize: playAreaSize)
                    ballShadow(throwMoment: throwMoment, playAreaSize: playAreaSize)
                    playmate(
                        mascot: leftPlaymateMascot,
                        isOnLeft: true,
                        throwMoment: throwMoment,
                        playAreaSize: playAreaSize
                    )
                    playmate(
                        mascot: rightPlaymateMascot,
                        isOnLeft: false,
                        throwMoment: throwMoment,
                        playAreaSize: playAreaSize
                    )
                    ball(throwMoment: throwMoment, playAreaSize: playAreaSize)
                }
            }
        }
        .background(theme.foreground(opacity: 0.04))
        .accessibilityHidden(true)
    }

    // MARK: - Choreography

    /// Where we are in the game right now.
    private struct ThrowMoment {
        /// 0 at the throw, 1 at the catch.
        let progressThroughThrow: Double
        /// True while the ball travels from the left playmate to the right one.
        let isThrownFromLeft: Bool
    }

    private func currentThrowMoment(at date: Date) -> ThrowMoment {
        let elapsedSeconds = date.timeIntervalSinceReferenceDate
        let throwsSoFar = elapsedSeconds / secondsPerThrow
        let throwIndex = Int(throwsSoFar.rounded(.down))
        return ThrowMoment(
            progressThroughThrow: throwsSoFar - Double(throwIndex),
            isThrownFromLeft: throwIndex % 2 == 0
        )
    }

    private func groundY(playAreaSize: CGSize) -> CGFloat {
        playAreaSize.height - groundInsetFromBottom
    }

    /// Hand height of each playmate, where the ball leaves and lands.
    private func ballLaunchY(playAreaSize: CGSize) -> CGFloat {
        groundY(playAreaSize: playAreaSize) - petSideLength * 0.55
    }

    private func playmateCenterX(isOnLeft: Bool, playAreaSize: CGSize) -> CGFloat {
        isOnLeft
            ? petInsetFromSides + petSideLength / 2
            : playAreaSize.width - petInsetFromSides - petSideLength / 2
    }

    // MARK: - Pieces

    private func groundLine(playAreaSize: CGSize) -> some View {
        Path { groundPath in
            let lineY = groundY(playAreaSize: playAreaSize) + 1
            groundPath.move(to: CGPoint(x: 16, y: lineY))
            groundPath.addLine(to: CGPoint(x: playAreaSize.width - 16, y: lineY))
        }
        .stroke(theme.foreground(opacity: 0.12), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
    }

    private func playmate(mascot: WaitWhatMascot, isOnLeft: Bool, throwMoment: ThrowMoment, playAreaSize: CGSize) -> some View {
        let isThrower = throwMoment.isThrownFromLeft == isOnLeft
        let progress = throwMoment.progressThroughThrow

        // Thrower waves the ball off; catcher perks up as it comes in, then
        // gives a happy little hop right after catching (start of its own throw).
        let playmateState: PetAnimationState
        var hopHeight: CGFloat = 0
        if isThrower {
            if progress < 0.18 {
                playmateState = .hello
                hopHeight = CGFloat(sin(progress / 0.18 * .pi)) * 5
            } else {
                playmateState = .idle
            }
        } else {
            playmateState = progress > 0.55 ? .listening : .idle
        }

        let centerX = playmateCenterX(isOnLeft: isOnLeft, playAreaSize: playAreaSize)
        return PetSpriteView(mascot: mascot, state: playmateState, scale: 2, isMirrored: !isOnLeft)
            .position(
                x: centerX,
                y: groundY(playAreaSize: playAreaSize) - petSideLength / 2 - hopHeight
            )
    }

    private func ballPosition(throwMoment: ThrowMoment, playAreaSize: CGSize) -> CGPoint {
        let progress = throwMoment.progressThroughThrow
        let startX = playmateCenterX(isOnLeft: throwMoment.isThrownFromLeft, playAreaSize: playAreaSize)
            + (throwMoment.isThrownFromLeft ? 18 : -18)
        let endX = playmateCenterX(isOnLeft: !throwMoment.isThrownFromLeft, playAreaSize: playAreaSize)
            + (throwMoment.isThrownFromLeft ? -18 : 18)
        let ballX = startX + (endX - startX) * CGFloat(progress)
        let ballY = ballLaunchY(playAreaSize: playAreaSize) - CGFloat(sin(progress * .pi)) * throwArcHeight
        // Snap to whole points so the pixel ball stays crisp like the sprites.
        return CGPoint(x: ballX.rounded(), y: ballY.rounded())
    }

    private func ball(throwMoment: ThrowMoment, playAreaSize: CGSize) -> some View {
        Rectangle()
            .fill(theme.accent)
            .frame(width: ballSideLength, height: ballSideLength)
            .position(ballPosition(throwMoment: throwMoment, playAreaSize: playAreaSize))
    }

    /// A soft shadow on the ground under the ball, smaller the higher it flies.
    private func ballShadow(throwMoment: ThrowMoment, playAreaSize: CGSize) -> some View {
        let heightFraction = CGFloat(sin(throwMoment.progressThroughThrow * .pi))
        let ballX = ballPosition(throwMoment: throwMoment, playAreaSize: playAreaSize).x
        return Ellipse()
            .fill(theme.foreground(opacity: 0.10 - 0.05 * Double(heightFraction)))
            .frame(width: 12 - 6 * heightFraction, height: 3)
            .position(x: ballX, y: groundY(playAreaSize: playAreaSize) + 1)
    }
}
