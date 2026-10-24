//
//  PetAnnotationLayerView.swift
//  Hoot
//
//  The marks hoot draws over the thing it is explaining: arrows, loose
//  rings, wobbly underlines and little label chips from the tutor's [DRAW:]
//  tags. A sibling of the index-card frame (PetPointingFrame.swift,
//  POINTING.md): the same 2pt accent pixels, no anti-aliasing, no radius, no
//  shadow, stepped motion with no easing. The marks appear one after another
//  once the frame has drawn in, so they land in time with what hoot is
//  saying, and they fade out with the frame.
//
//  One of these lives in every display's overlay window and draws only the
//  marks that belong to that display.
//

import AppKit
import SwiftUI

struct PetAnnotationLayerView: View {
    /// This display's frame in AppKit global coordinates.
    let screenFrame: CGRect
    /// Every mark from the reply (all displays); filtered to this screen here.
    let annotations: [HootResolvedAnnotation]
    /// True from the moment the frame is on screen until it starts fading:
    /// the marks begin their reveal when this turns true.
    let isPointingFrameShown: Bool
    /// The marks share the frame's fade-out.
    let pointingFrameOpacity: Double
    let theme: WaitWhatTheme

    /// When the reveal started; nil until the frame is up (nothing drawn).
    @State private var revealStartDate: Date?
    /// Stops the timeline ticking once every mark is fully drawn.
    @State private var isRevealComplete = false

    static let pixelSize: CGFloat = 2
    /// The frame draws in over 240ms (POINTING.md); the first mark waits for it.
    static let secondsBeforeFirstMark: TimeInterval = 0.24
    static let secondsBetweenMarkStarts: TimeInterval = 0.16
    static let secondsPerMark: TimeInterval = 0.24
    static let stepsPerMark = 8
    /// The ring sits a little outside the box it loops around.
    static let ringPaddingAroundBox: CGFloat = 4
    static let labelChipHeight: CGFloat = 18
    static let labelChipHorizontalPadding: CGFloat = 7
    static let arrowheadWingLength: CGFloat = 10

    var body: some View {
        let annotationsOnThisScreen = annotations.filter { $0.displayFrame == screenFrame }
        let isTimelinePaused = revealStartDate == nil || isRevealComplete || annotationsOnThisScreen.isEmpty

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isTimelinePaused)) { timelineContext in
            Canvas { graphicsContext, canvasSize in
                guard let revealStartDate else { return }
                let secondsSinceRevealStart = timelineContext.date.timeIntervalSince(revealStartDate)
                for annotation in annotationsOnThisScreen {
                    // Marks start 160ms apart in tag order, across all screens,
                    // so the order hoot wrote them in is the order they appear.
                    let markStartSeconds = Self.secondsBeforeFirstMark + Double(annotation.id) * Self.secondsBetweenMarkStarts
                    let stepCount = Self.drawStepCount(forSecondsSinceMarkStart: secondsSinceRevealStart - markStartSeconds)
                    guard stepCount > 0 else { continue }
                    draw(annotation, stepCount: stepCount, canvasSize: canvasSize, in: &graphicsContext)
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .opacity(pointingFrameOpacity)
        .onChange(of: isPointingFrameShown, initial: true) { _, isShown in
            // The reveal starts when the frame comes up; when the frame starts
            // fading the marks stay fully drawn and fade with it.
            if isShown {
                revealStartDate = Date()
                isRevealComplete = false
            }
        }
        .onChange(of: annotations) { _, newAnnotations in
            // A new reply (or the end of pointing) replaces the marks: forget
            // the old reveal so stale marks never flash up for the new frame.
            if newAnnotations.isEmpty || !isPointingFrameShown {
                revealStartDate = nil
            } else {
                revealStartDate = Date()
            }
            isRevealComplete = false
        }
        .task(id: revealStartDate) {
            guard revealStartDate != nil else { return }
            let lastMarkIndex = annotations.map(\.id).max() ?? 0
            let totalRevealSeconds = Self.secondsBeforeFirstMark
                + Double(lastMarkIndex) * Self.secondsBetweenMarkStarts
                + Self.secondsPerMark
                + 0.1
            try? await Task.sleep(nanoseconds: UInt64(totalRevealSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isRevealComplete = true
        }
    }

    /// 0 before the mark starts, then 1…8 as it draws in over 240ms (one
    /// step per 30ms, the first shown the instant the mark starts). Reduce
    /// Motion skips the draw and shows every mark whole.
    static func drawStepCount(forSecondsSinceMarkStart secondsSinceMarkStart: TimeInterval) -> Int {
        guard secondsSinceMarkStart >= 0 else { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return stepsPerMark }
        let secondsPerStep = secondsPerMark / Double(stepsPerMark)
        return min(stepsPerMark, Int(secondsSinceMarkStart / secondsPerStep) + 1)
    }

    // MARK: - Drawing one mark

    private func draw(_ annotation: HootResolvedAnnotation, stepCount: Int, canvasSize: CGSize, in graphicsContext: inout GraphicsContext) {
        let progress = CGFloat(stepCount) / CGFloat(Self.stepsPerMark)
        switch annotation.shape {
        case let .arrow(fromGlobalPoint, toGlobalPoint):
            drawArrow(
                from: localPoint(fromGlobalPoint: fromGlobalPoint),
                to: localPoint(fromGlobalPoint: toGlobalPoint),
                stepCount: stepCount,
                in: &graphicsContext
            )
        case let .ring(globalBoxRect):
            // Global rects grow upward, so the box's top-left on screen is its
            // (minX, maxY) corner.
            let localTopLeft = localPoint(fromGlobalPoint: CGPoint(x: globalBoxRect.minX, y: globalBoxRect.maxY))
            let localBoxRect = CGRect(origin: localTopLeft, size: globalBoxRect.size)
            drawRing(around: localBoxRect, progress: progress, in: &graphicsContext)
        case let .underline(startGlobalPoint, width):
            drawUnderline(from: localPoint(fromGlobalPoint: startGlobalPoint), width: width, progress: progress, in: &graphicsContext)
        case let .label(topLeftGlobalPoint, text):
            drawLabelChip(
                topLeft: localPoint(fromGlobalPoint: topLeftGlobalPoint),
                text: text,
                stepCount: stepCount,
                canvasSize: canvasSize,
                in: &graphicsContext
            )
        }
    }

    /// The shaft draws in over the first six steps, then one wing of the
    /// head per remaining step, so the arrow visibly "arrives".
    private func drawArrow(from startPoint: CGPoint, to endPoint: CGPoint, stepCount: Int, in graphicsContext: inout GraphicsContext) {
        let shaftCells = Self.pixelCells(alongLineFrom: startPoint, to: endPoint)
        let shaftProgress = min(1, CGFloat(stepCount) / 6)
        let visibleShaftCellCount = Int((CGFloat(shaftCells.count) * shaftProgress).rounded(.up))
        var cells = Array(shaftCells.prefix(visibleShaftCellCount))

        let shaftLength = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        if shaftLength > 0 {
            let direction = CGPoint(x: (endPoint.x - startPoint.x) / shaftLength, y: (endPoint.y - startPoint.y) / shaftLength)
            // The two wings point back from the tip, 30° either side of the shaft.
            let wingEndPoints = [150.0, -150.0].map { wingAngleInDegrees -> CGPoint in
                let wingAngle = wingAngleInDegrees * .pi / 180
                let rotatedDirection = CGPoint(
                    x: direction.x * cos(wingAngle) - direction.y * sin(wingAngle),
                    y: direction.x * sin(wingAngle) + direction.y * cos(wingAngle)
                )
                return CGPoint(
                    x: endPoint.x + rotatedDirection.x * Self.arrowheadWingLength,
                    y: endPoint.y + rotatedDirection.y * Self.arrowheadWingLength
                )
            }
            if stepCount >= 7 { cells += Self.pixelCells(alongLineFrom: endPoint, to: wingEndPoints[0]) }
            if stepCount >= 8 { cells += Self.pixelCells(alongLineFrom: endPoint, to: wingEndPoints[1]) }
        }
        fill(cells: cells, in: &graphicsContext)
    }

    /// A loose ring: an ellipse padded past the box, with a slow wobble in
    /// its radius so it reads as drawn by hand, traced clockwise from the
    /// upper left and closing a little past where it began.
    private func drawRing(around boxRect: CGRect, progress: CGFloat, in graphicsContext: inout GraphicsContext) {
        let paddedRect = boxRect.insetBy(dx: -Self.ringPaddingAroundBox, dy: -Self.ringPaddingAroundBox)
        let radiusX = max(paddedRect.width / 2, 8)
        let radiusY = max(paddedRect.height / 2, 8)
        let center = CGPoint(x: paddedRect.midX, y: paddedRect.midY)

        // Ramanujan's perimeter estimate, one sample per 2pt pixel.
        let perimeter = CGFloat.pi * (3 * (radiusX + radiusY) - sqrt((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)))
        let sampleCountPerLoop = max(24, Int(perimeter / Self.pixelSize))
        let overshootSampleCount = sampleCountPerLoop / 12
        let startAngle: CGFloat = -2.0 // upper left, in radians

        var outlinePoints: [CGPoint] = []
        for sampleIndex in 0...(sampleCountPerLoop + overshootSampleCount) {
            let angle = startAngle + 2 * .pi * CGFloat(sampleIndex) / CGFloat(sampleCountPerLoop)
            // Two slow sine wobbles keep it loose without looking broken.
            let wobble = 1.5 * sin(3 * angle + 0.9) + 1.0 * sin(7 * angle + 2.1)
            outlinePoints.append(CGPoint(
                x: center.x + (radiusX + wobble) * cos(angle),
                y: center.y + (radiusY + wobble) * sin(angle)
            ))
        }
        let ringCells = Self.pixelCells(alongPolyline: outlinePoints)
        let visibleCellCount = Int((CGFloat(ringCells.count) * progress).rounded(.up))
        fill(cells: Array(ringCells.prefix(visibleCellCount)), in: &graphicsContext)
    }

    /// A 2pt line revealed left to right, stepping up or down a pixel every
    /// so often like a quick pen stroke.
    private func drawUnderline(from startPoint: CGPoint, width: CGFloat, progress: CGFloat, in graphicsContext: inout GraphicsContext) {
        let segmentLength: CGFloat = 12
        let wobblePattern: [CGFloat] = [0, 0, 2, 2, 0, -2, 0, 2]
        var polylinePoints: [CGPoint] = []
        var distanceAlongLine: CGFloat = 0
        var segmentIndex = 0
        while distanceAlongLine < width {
            polylinePoints.append(CGPoint(x: startPoint.x + distanceAlongLine, y: startPoint.y + wobblePattern[segmentIndex % wobblePattern.count]))
            distanceAlongLine += segmentLength
            segmentIndex += 1
        }
        polylinePoints.append(CGPoint(x: startPoint.x + width, y: startPoint.y + wobblePattern[segmentIndex % wobblePattern.count]))

        let lineCells = Self.pixelCells(alongPolyline: polylinePoints)
        let visibleCellCount = Int((CGFloat(lineCells.count) * progress).rounded(.up))
        fill(cells: Array(lineCells.prefix(visibleCellCount)), in: &graphicsContext)
    }

    /// The frame's tab, standing on its own: accent chip with 2×2 notches on
    /// all four corners, JetBrains Mono 10.5 semibold on-accent text. Wipes
    /// in left to right over four steps while rising 4pt → 0 in two more.
    private func drawLabelChip(topLeft: CGPoint, text: String, stepCount: Int, canvasSize: CGSize, in graphicsContext: inout GraphicsContext) {
        let resolvedText = graphicsContext.resolve(
            Text(text.lowercased())
                .font(.jetBrainsMono(10.5, weight: .semibold))
                .foregroundColor(theme.onAccent)
        )
        let textSize = resolvedText.measure(in: CGSize(width: 400, height: Self.labelChipHeight))
        let chipWidth = Self.snappedToPixelGrid(textSize.width + Self.labelChipHorizontalPadding * 2, roundingUp: true)
        let chipHeight = Self.labelChipHeight

        // Keep the chip on screen, and on the pixel grid.
        let riseOffset: CGFloat = stepCount <= 4 ? 4 : (stepCount <= 6 ? 2 : 0)
        let chipOrigin = CGPoint(
            x: Self.snappedToPixelGrid(min(max(topLeft.x, 4), canvasSize.width - chipWidth - 4)),
            y: Self.snappedToPixelGrid(min(max(topLeft.y, 4), canvasSize.height - chipHeight - 4)) + riseOffset
        )
        let wipeProgress = min(1, CGFloat(stepCount) / 4)
        let visibleWidth = Self.snappedToPixelGrid(chipWidth * wipeProgress, roundingUp: true)

        let notch = Self.pixelSize
        var chipPath = Path()
        chipPath.addRect(CGRect(x: chipOrigin.x + notch, y: chipOrigin.y, width: chipWidth - notch * 2, height: chipHeight))
        chipPath.addRect(CGRect(x: chipOrigin.x, y: chipOrigin.y + notch, width: chipWidth, height: chipHeight - notch * 2))

        var clippedContext = graphicsContext
        clippedContext.clip(to: Path(CGRect(x: chipOrigin.x, y: chipOrigin.y, width: visibleWidth, height: chipHeight)))
        clippedContext.fill(chipPath, with: .color(theme.accent))
        if stepCount > 4 {
            clippedContext.draw(
                resolvedText,
                at: CGPoint(x: chipOrigin.x + chipWidth / 2, y: chipOrigin.y + chipHeight / 2 - 0.5),
                anchor: .center
            )
        }
    }

    // MARK: - Pixel helpers

    private func fill(cells: [CGPoint], in graphicsContext: inout GraphicsContext) {
        guard !cells.isEmpty else { return }
        var cellsPath = Path()
        for cellOrigin in cells {
            cellsPath.addRect(CGRect(origin: cellOrigin, size: CGSize(width: Self.pixelSize, height: Self.pixelSize)))
        }
        graphicsContext.fill(cellsPath, with: .color(theme.accent))
    }

    /// The 2pt cells along a line, one per step on the longer axis so the
    /// run never has gaps, in order from start to end (for the reveal).
    static func pixelCells(alongLineFrom startPoint: CGPoint, to endPoint: CGPoint) -> [CGPoint] {
        let startCellX = (startPoint.x / pixelSize).rounded(.down)
        let startCellY = (startPoint.y / pixelSize).rounded(.down)
        let deltaCellsX = (endPoint.x / pixelSize).rounded(.down) - startCellX
        let deltaCellsY = (endPoint.y / pixelSize).rounded(.down) - startCellY
        let cellCount = Int(max(abs(deltaCellsX), abs(deltaCellsY)))
        guard cellCount > 0 else {
            return [CGPoint(x: startCellX * pixelSize, y: startCellY * pixelSize)]
        }
        return (0...cellCount).map { cellIndex in
            let fraction = CGFloat(cellIndex) / CGFloat(cellCount)
            return CGPoint(
                x: (startCellX + (deltaCellsX * fraction).rounded()) * pixelSize,
                y: (startCellY + (deltaCellsY * fraction).rounded()) * pixelSize
            )
        }
    }

    /// Cells along a chain of points; each segment's first cell is the
    /// previous segment's last, so it is skipped.
    static func pixelCells(alongPolyline points: [CGPoint]) -> [CGPoint] {
        guard let firstPoint = points.first else { return [] }
        var cells: [CGPoint] = []
        var previousPoint = firstPoint
        for (pointIndex, point) in points.enumerated() {
            let segmentCells = pixelCells(alongLineFrom: previousPoint, to: point)
            cells += pointIndex == 0 ? segmentCells : Array(segmentCells.dropFirst())
            previousPoint = point
        }
        return cells
    }

    static func snappedToPixelGrid(_ value: CGFloat, roundingUp: Bool = false) -> CGFloat {
        (value / pixelSize).rounded(roundingUp ? .up : .down) * pixelSize
    }

    private func localPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint {
        PetOverlayCoordinateSpace.swiftUIPoint(fromGlobalPoint: globalPoint, inScreenFrame: screenFrame)
    }
}
