//
//  PetNapkinSketchLayerView.swift
//  Hoot
//
//  Draws the tutor's napkin sketch (HootNapkinSketch.swift) on the screen
//  overlay: a faint paper card with 2pt accent pixel strokes that look
//  hand-drawn (a little jitter, overshot line ends, rects as four imperfect
//  strokes, ellipses that don't quite close) and are revealed at pen speed,
//  one stroke after another, as if hoot were sketching while it talks.
//
//  Timing: strokes are grouped by spoken sentence. A group may start once
//  its sentence is being spoken, which this view reads off the revealed
//  answer text (it moves in step with the voice), so no TTS wiring is
//  needed. One pen draws everything in order: a stroke starts when its
//  group has started and the previous stroke is finished.
//
//  Same vocabulary as the frame and the marks (POINTING.md): 2pt cells, no
//  anti-aliasing, no radius, no shadow, stepped motion, no `withAnimation`.
//  One of these lives in every display's overlay window and draws only a
//  napkin that belongs to that display.
//

import AppKit
import SwiftUI

struct PetNapkinSketchLayerView: View {
    /// This display's frame in AppKit global coordinates.
    let screenFrame: CGRect
    /// The current napkin, or nil (which starts the fade-out).
    let napkinSketch: HootNapkinSketchState?
    /// The answer text revealed so far, in step with the voice.
    let spokenTextRevealedSoFar: String
    let theme: WaitWhatTheme

    /// The napkin being drawn: kept after `napkinSketch` turns nil so it
    /// can fade out instead of vanishing.
    @State private var shownSketch: HootNapkinSketchState?
    /// Strokes rasterized into local 2pt cells once per napkin.
    @State private var rasterizedStrokes: [RasterizedNapkinStroke] = []
    /// When each sentence group was allowed to start (1-based sentence
    /// index). `.distantPast` for sentences already spoken when the napkin
    /// appeared, so they draw at once.
    @State private var groupStartDates: [Int: Date] = [:]
    /// Stops the timeline once the pen has finished every started group.
    @State private var isPenFinished = false
    /// 1 → 0.66 → 0.33 → 0 over 150ms when the napkin is cleared.
    @State private var fadeOpacity: Double = 1
    @State private var fadeTask: Task<Void, Never>?

    static let pixelSize: CGFloat = 2
    /// About 180 cells per second, stepped every 30ms.
    static let secondsPerStep: TimeInterval = 0.03
    static let cellsPerStep: Double = 5.4
    /// Each typed character costs this much pen time.
    static let penCellsPerTextCharacter = 3
    static let arrowheadWingLength: CGFloat = 8
    static let textFontSize: CGFloat = 10.5

    var body: some View {
        let isNapkinOnThisScreen = shownSketch.map { $0.displayFrame == screenFrame } ?? false
        let isTimelinePaused = !isNapkinOnThisScreen || (isPenFinished && fadeTask == nil)

        TimelineView(.animation(minimumInterval: Self.secondsPerStep, paused: isTimelinePaused)) { timelineContext in
            Canvas { graphicsContext, _ in
                guard let shownSketch, isNapkinOnThisScreen else { return }
                drawPaper(for: shownSketch, in: &graphicsContext)
                let penSchedule = Self.penSchedule(for: rasterizedStrokes, groupStartDates: groupStartDates)
                for (strokeIndex, stroke) in rasterizedStrokes.enumerated() {
                    guard let strokeTiming = penSchedule[strokeIndex] else { continue }
                    let visibleCellCount = Self.visibleCellCount(
                        secondsSinceStrokeStart: timelineContext.date.timeIntervalSince(strokeTiming.start),
                        totalCellCount: stroke.penCellCount
                    )
                    guard visibleCellCount > 0 else { continue }
                    draw(stroke, visibleCellCount: visibleCellCount, in: &graphicsContext)
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .opacity(fadeOpacity)
        .onChange(of: napkinSketch, initial: true) { _, newSketch in
            handleNapkinChange(newSketch)
        }
        .onChange(of: currentSentenceIndex, initial: true) { _, sentenceIndex in
            startGroups(upTo: sentenceIndex)
        }
        .task(id: groupStartDates) {
            // Sleep until the pen is done with every started group, then let
            // the timeline rest; a newly started group restarts the wait.
            isPenFinished = false
            let penSchedule = Self.penSchedule(for: rasterizedStrokes, groupStartDates: groupStartDates)
            guard let lastFinishDate = penSchedule.values.map(\.finish).max() else { return }
            let secondsUntilFinished = lastFinishDate.timeIntervalSinceNow + 0.1
            if secondsUntilFinished > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secondsUntilFinished * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            isPenFinished = true
        }
    }

    // MARK: - State changes

    /// 1-based index of the sentence being spoken, from the revealed text.
    private var currentSentenceIndex: Int {
        guard let shownSketch else { return 0 }
        return shownSketch.sentenceIndexBeingSpoken(revealedCharacterCount: spokenTextRevealedSoFar.count)
    }

    private func handleNapkinChange(_ newSketch: HootNapkinSketchState?) {
        if let newSketch {
            fadeTask?.cancel()
            fadeTask = nil
            fadeOpacity = 1
            shownSketch = newSketch
            rasterizedStrokes = newSketch.strokes.map { stroke in
                RasterizedNapkinStroke(stroke: stroke, screenFrame: screenFrame)
            }
            groupStartDates = [:]
            isPenFinished = false
            startGroups(upTo: currentSentenceIndex)
        } else if shownSketch != nil, fadeTask == nil {
            fadeTask = Task { @MainActor in
                for fadeStep in 1...3 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled else { return }
                    fadeOpacity = 1 - Double(fadeStep) / 3
                }
                shownSketch = nil
                rasterizedStrokes = []
                groupStartDates = [:]
                fadeOpacity = 1
                fadeTask = nil
            }
        }
    }

    /// Lets every group up to the sentence being spoken start: the current
    /// one now, earlier ones (skipped while the napkin wasn't up yet) at
    /// once. A sentence index past the end still starts the last groups,
    /// so a stroke the tutor filed under "s9" of a four-sentence reply
    /// draws when the reply ends.
    private func startGroups(upTo sentenceIndex: Int) {
        guard let shownSketch, sentenceIndex > 0 else { return }
        let isLastSentence = sentenceIndex >= shownSketch.sentenceCount
        let highestGroupToStart = isLastSentence
            ? max(sentenceIndex, rasterizedStrokes.map(\.stroke.sentenceIndex).max() ?? sentenceIndex)
            : sentenceIndex
        var updatedStartDates = groupStartDates
        for groupIndex in 1...max(highestGroupToStart, 1) where updatedStartDates[groupIndex] == nil {
            let isGroupBeingSpokenNow = groupIndex >= sentenceIndex
            updatedStartDates[groupIndex] = isGroupBeingSpokenNow ? Date() : .distantPast
        }
        if updatedStartDates != groupStartDates {
            groupStartDates = updatedStartDates
        }
    }

    // MARK: - Pen timing

    struct StrokeTiming: Equatable {
        let start: Date
        let finish: Date
    }

    /// One pen, strokes in order: a stroke starts when its group has
    /// started and the previous stroke is done. Strokes whose group hasn't
    /// started are left out (and skipped over by the pen).
    static func penSchedule(for strokes: [RasterizedNapkinStroke], groupStartDates: [Int: Date]) -> [Int: StrokeTiming] {
        var schedule: [Int: StrokeTiming] = [:]
        var penFreeAtDate = Date.distantPast
        for (strokeIndex, stroke) in strokes.enumerated() {
            guard let groupStartDate = groupStartDates[stroke.stroke.sentenceIndex] else { continue }
            let strokeStartDate = max(groupStartDate, penFreeAtDate)
            let strokeFinishDate = strokeStartDate.addingTimeInterval(secondsToDraw(cellCount: stroke.penCellCount))
            schedule[strokeIndex] = StrokeTiming(start: strokeStartDate, finish: strokeFinishDate)
            penFreeAtDate = strokeFinishDate
        }
        return schedule
    }

    static func secondsToDraw(cellCount: Int) -> TimeInterval {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        return (Double(cellCount) / cellsPerStep).rounded(.up) * secondsPerStep
    }

    /// Cells of a stroke shown so far, stepped every 30ms (the first step
    /// shows the instant the stroke starts). Reduce Motion shows it whole.
    static func visibleCellCount(secondsSinceStrokeStart: TimeInterval, totalCellCount: Int) -> Int {
        guard secondsSinceStrokeStart >= 0 else { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return totalCellCount }
        let stepCount = Int(secondsSinceStrokeStart / secondsPerStep) + 1
        return min(totalCellCount, Int(Double(stepCount) * cellsPerStep))
    }

    // MARK: - Drawing

    /// The paper: a faint card with 2pt notched corners (like the frame's
    /// tab) and a fainter edge, so the sketch reads as its own little
    /// surface over whatever is behind it.
    private func drawPaper(for sketch: HootNapkinSketchState, in graphicsContext: inout GraphicsContext) {
        let paperRect = localRect(fromGlobalRect: sketch.paperRectInGlobalSpace)
        let notch = Self.pixelSize
        var paperPath = Path()
        paperPath.addRect(CGRect(x: paperRect.minX + notch, y: paperRect.minY, width: paperRect.width - notch * 2, height: paperRect.height))
        paperPath.addRect(CGRect(x: paperRect.minX, y: paperRect.minY + notch, width: paperRect.width, height: paperRect.height - notch * 2))
        graphicsContext.fill(paperPath, with: .color(theme.foreground(opacity: theme.isDark ? 0.06 : 0.04)))

        // The edge: the same notched outline, 2pt thick, as a pixel path.
        var edgePath = Path()
        edgePath.addRect(CGRect(x: paperRect.minX + notch, y: paperRect.minY, width: paperRect.width - notch * 2, height: notch))
        edgePath.addRect(CGRect(x: paperRect.minX + notch, y: paperRect.maxY - notch, width: paperRect.width - notch * 2, height: notch))
        edgePath.addRect(CGRect(x: paperRect.minX, y: paperRect.minY + notch, width: notch, height: paperRect.height - notch * 2))
        edgePath.addRect(CGRect(x: paperRect.maxX - notch, y: paperRect.minY + notch, width: notch, height: paperRect.height - notch * 2))
        graphicsContext.fill(edgePath, with: .color(theme.foreground(opacity: theme.isDark ? 0.14 : 0.10)))
    }

    private func draw(_ stroke: RasterizedNapkinStroke, visibleCellCount: Int, in graphicsContext: inout GraphicsContext) {
        switch stroke.content {
        case let .cells(cells):
            fill(cells: Array(cells.prefix(visibleCellCount)), in: &graphicsContext)
        case let .text(topLeft, words):
            // Typed in: each character costs a few cells of pen time.
            let visibleCharacterCount = min(words.count, visibleCellCount / Self.penCellsPerTextCharacter + 1)
            let visibleWords = String(words.prefix(visibleCharacterCount))
            let resolvedText = graphicsContext.resolve(
                Text(visibleWords)
                    .font(.jetBrainsMono(Self.textFontSize, weight: .medium))
                    .foregroundColor(theme.ink)
            )
            graphicsContext.draw(resolvedText, at: topLeft, anchor: .topLeading)
        }
    }

    private func fill(cells: [CGPoint], in graphicsContext: inout GraphicsContext) {
        guard !cells.isEmpty else { return }
        var cellsPath = Path()
        for cellOrigin in cells {
            cellsPath.addRect(CGRect(origin: cellOrigin, size: CGSize(width: Self.pixelSize, height: Self.pixelSize)))
        }
        graphicsContext.fill(cellsPath, with: .color(theme.accent))
    }

    // MARK: - Coordinates

    private func localRect(fromGlobalRect globalRect: CGRect) -> CGRect {
        // Global rects grow upward: the top-left on screen is (minX, maxY).
        let topLeft = PetOverlayCoordinateSpace.swiftUIPoint(
            fromGlobalPoint: CGPoint(x: globalRect.minX, y: globalRect.maxY),
            inScreenFrame: screenFrame
        )
        return CGRect(origin: topLeft, size: globalRect.size)
    }
}

// MARK: - Rasterized strokes

/// A stroke turned into the 2pt cells (local coordinates of one screen)
/// the pen will lay down in order, with its hand-drawn imperfections baked
/// in: ±1 cell of jitter along the way and a 1–2 cell overshoot at line
/// ends, both from a generator seeded by the stroke's index so a redraw
/// never makes the sketch wriggle.
struct RasterizedNapkinStroke: Equatable {
    enum Content: Equatable {
        case cells([CGPoint])
        case text(topLeft: CGPoint, words: String)
    }

    let stroke: HootNapkinStroke
    let content: Content
    /// How much pen time the stroke takes, in cells.
    let penCellCount: Int

    static let pixelSize = PetNapkinSketchLayerView.pixelSize

    init(stroke: HootNapkinStroke, screenFrame: CGRect) {
        self.stroke = stroke
        var pen = NapkinPenRandom(seed: UInt64(stroke.id + 1))
        func local(_ globalPoint: CGPoint) -> CGPoint {
            PetOverlayCoordinateSpace.swiftUIPoint(fromGlobalPoint: globalPoint, inScreenFrame: screenFrame)
        }
        func localRect(_ globalRect: CGRect) -> CGRect {
            CGRect(origin: local(CGPoint(x: globalRect.minX, y: globalRect.maxY)), size: globalRect.size)
        }

        switch stroke.primitive {
        case let .line(from, to):
            let cells = Self.handDrawnLineCells(from: local(from), to: local(to), pen: &pen)
            content = .cells(cells)
            penCellCount = cells.count
        case let .arrow(from, to):
            let cells = Self.arrowCells(from: local(from), to: local(to), pen: &pen)
            content = .cells(cells)
            penCellCount = cells.count
        case let .rect(rect):
            let cells = Self.rectCells(localRect(rect), pen: &pen)
            content = .cells(cells)
            penCellCount = cells.count
        case let .ellipse(rect):
            let cells = Self.ellipseCells(in: localRect(rect), pen: &pen)
            content = .cells(cells)
            penCellCount = cells.count
        case let .dot(point):
            let cells = Self.dotCells(at: local(point))
            content = .cells(cells)
            penCellCount = cells.count
        case let .curve(from, control, to):
            let cells = Self.curveCells(from: local(from), control: local(control), to: local(to), pen: &pen)
            content = .cells(cells)
            penCellCount = cells.count
        case let .text(topLeft, words):
            let lowercasedWords = words.lowercased()
            content = .text(topLeft: local(topLeft), words: lowercasedWords)
            penCellCount = lowercasedWords.count * PetNapkinSketchLayerView.penCellsPerTextCharacter
        }
    }

    // MARK: Shapes

    /// A line as a wobbly polyline: vertices every ~14pt, each nudged by
    /// up to one cell, and both ends overshot by 1–2 cells.
    static func handDrawnLineCells(from startPoint: CGPoint, to endPoint: CGPoint, pen: inout NapkinPenRandom) -> [CGPoint] {
        let length = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        guard length > 0 else { return dotCells(at: startPoint) }
        let direction = CGPoint(x: (endPoint.x - startPoint.x) / length, y: (endPoint.y - startPoint.y) / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let overshootAtStart = CGFloat(pen.nextInt(in: 1...2)) * pixelSize
        let overshootAtEnd = CGFloat(pen.nextInt(in: 1...2)) * pixelSize
        let overshotStart = CGPoint(x: startPoint.x - direction.x * overshootAtStart, y: startPoint.y - direction.y * overshootAtStart)
        let overshotEnd = CGPoint(x: endPoint.x + direction.x * overshootAtEnd, y: endPoint.y + direction.y * overshootAtEnd)

        let vertexCount = max(2, Int(length / 14) + 1)
        var vertices: [CGPoint] = []
        for vertexIndex in 0...vertexCount {
            let fraction = CGFloat(vertexIndex) / CGFloat(vertexCount)
            var vertex = CGPoint(
                x: overshotStart.x + (overshotEnd.x - overshotStart.x) * fraction,
                y: overshotStart.y + (overshotEnd.y - overshotStart.y) * fraction
            )
            // The ends stay put so shapes still meet; the middle wanders.
            if vertexIndex != 0, vertexIndex != vertexCount {
                let wobble = CGFloat(pen.nextInt(in: -1...1)) * pixelSize
                vertex.x += normal.x * wobble
                vertex.y += normal.y * wobble
            }
            vertices.append(vertex)
        }
        return pixelCells(alongPolyline: vertices)
    }

    /// Shaft, then a two-stroke pixel head drawn back from the tip.
    static func arrowCells(from startPoint: CGPoint, to endPoint: CGPoint, pen: inout NapkinPenRandom) -> [CGPoint] {
        var cells = handDrawnLineCells(from: startPoint, to: endPoint, pen: &pen)
        let length = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        guard length > 0 else { return cells }
        let direction = CGPoint(x: (endPoint.x - startPoint.x) / length, y: (endPoint.y - startPoint.y) / length)
        for wingAngleInDegrees in [150.0, -150.0] {
            let wingAngle = wingAngleInDegrees * .pi / 180
            let wingDirection = CGPoint(
                x: direction.x * cos(wingAngle) - direction.y * sin(wingAngle),
                y: direction.x * sin(wingAngle) + direction.y * cos(wingAngle)
            )
            let wingLength = PetNapkinSketchLayerView.arrowheadWingLength + CGFloat(pen.nextInt(in: 0...1)) * pixelSize
            let wingEnd = CGPoint(x: endPoint.x + wingDirection.x * wingLength, y: endPoint.y + wingDirection.y * wingLength)
            cells += pixelCells(alongLineFrom: endPoint, to: wingEnd)
        }
        return cells
    }

    /// Four strokes drawn clockwise from the top-left, each starting a
    /// cell or so off the corner, so the corners don't quite meet.
    static func rectCells(_ rect: CGRect, pen: inout NapkinPenRandom) -> [CGPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        var cells: [CGPoint] = []
        for cornerIndex in 0..<4 {
            let nudge = CGPoint(
                x: CGFloat(pen.nextInt(in: -1...1)) * pixelSize,
                y: CGFloat(pen.nextInt(in: -1...1)) * pixelSize
            )
            let start = CGPoint(x: corners[cornerIndex].x + nudge.x, y: corners[cornerIndex].y + nudge.y)
            let end = corners[(cornerIndex + 1) % 4]
            cells += handDrawnLineCells(from: start, to: end, pen: &pen)
        }
        return cells
    }

    /// Traced from the upper left, around, stopping a little short so the
    /// loop has a visible gap, with a slow wobble in the radius.
    static func ellipseCells(in rect: CGRect, pen: inout NapkinPenRandom) -> [CGPoint] {
        let radiusX = max(rect.width / 2, 3)
        let radiusY = max(rect.height / 2, 3)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let perimeter = CGFloat.pi * (3 * (radiusX + radiusY) - sqrt((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)))
        let sampleCountPerLoop = max(16, Int(perimeter / pixelSize))
        // Stop 4–8% short of a full loop.
        let gapSampleCount = sampleCountPerLoop * pen.nextInt(in: 4...8) / 100
        let startAngle: CGFloat = -2.0 + CGFloat(pen.nextInt(in: -3...3)) / 10
        let wobblePhase = CGFloat(pen.nextInt(in: 0...6))
        var outlinePoints: [CGPoint] = []
        for sampleIndex in 0...(sampleCountPerLoop - gapSampleCount) {
            let angle = startAngle + 2 * .pi * CGFloat(sampleIndex) / CGFloat(sampleCountPerLoop)
            let wobble = 1.2 * sin(3 * angle + wobblePhase) + 0.8 * sin(7 * angle + 1.3)
            outlinePoints.append(CGPoint(
                x: center.x + (radiusX + wobble) * cos(angle),
                y: center.y + (radiusY + wobble) * sin(angle)
            ))
        }
        return pixelCells(alongPolyline: outlinePoints)
    }

    /// A 2×2 block of cells, centered on the point.
    static func dotCells(at point: CGPoint) -> [CGPoint] {
        let originX = (point.x / pixelSize).rounded(.down) * pixelSize - pixelSize
        let originY = (point.y / pixelSize).rounded(.down) * pixelSize - pixelSize
        return [
            CGPoint(x: originX, y: originY),
            CGPoint(x: originX + pixelSize, y: originY),
            CGPoint(x: originX + pixelSize, y: originY + pixelSize),
            CGPoint(x: originX, y: originY + pixelSize),
        ]
    }

    /// The quadratic sampled into a polyline (about one vertex per 10pt)
    /// with the same wobble as a line.
    static func curveCells(from startPoint: CGPoint, control controlPoint: CGPoint, to endPoint: CGPoint, pen: inout NapkinPenRandom) -> [CGPoint] {
        let roughLength = hypot(controlPoint.x - startPoint.x, controlPoint.y - startPoint.y)
            + hypot(endPoint.x - controlPoint.x, endPoint.y - controlPoint.y)
        let sampleCount = max(6, Int(roughLength / 10))
        var vertices: [CGPoint] = []
        for sampleIndex in 0...sampleCount {
            let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
            let oneMinusT = 1 - t
            var vertex = CGPoint(
                x: oneMinusT * oneMinusT * startPoint.x + 2 * oneMinusT * t * controlPoint.x + t * t * endPoint.x,
                y: oneMinusT * oneMinusT * startPoint.y + 2 * oneMinusT * t * controlPoint.y + t * t * endPoint.y
            )
            if sampleIndex != 0, sampleIndex != sampleCount {
                vertex.x += CGFloat(pen.nextInt(in: -1...1)) * pixelSize
                vertex.y += CGFloat(pen.nextInt(in: -1...1)) * pixelSize
            }
            vertices.append(vertex)
        }
        return pixelCells(alongPolyline: vertices)
    }

    // MARK: Pixel helpers (the same approach as the annotation layer)

    /// The 2pt cells along a line, one per step on the longer axis so the
    /// run never has gaps, in order from start to end.
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
}

/// A tiny deterministic generator (SplitMix64) so the napkin's
/// imperfections are the same every time it is drawn.
struct NapkinPenRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}
