//
//  HootNapkinSketch.swift
//  Hoot
//
//  The napkin sketch: a tiny diagram the tutor draws straight onto the
//  screen, in the same reply as the spoken answer, with a stroke language
//  small enough to write by hand:
//
//    [NAPKIN:s1: rect 10,10,30,30; text 12,44:before; s2: arrow 45,25,60,25]
//
//  The canvas is 100×56 units (16:9), primitives are separated by ";" and
//  grouped by the spoken sentence they belong to with an "s<k>:" prefix, so
//  each group draws while that sentence plays. This file holds the model,
//  the tolerant parser, the sentence bookkeeping and the on-screen layout
//  (where the paper goes); PetNapkinSketchLayerView.swift draws it.
//
//  Why a fourth picture medium: a [SKETCH:] costs a second model call and
//  a [VIDEO:] a minute of rendering; a napkin costs nothing and is on
//  screen the moment the reply ends, beside what the learner is reading.
//

import AppKit
import Foundation

// MARK: - Model (canvas units)

/// One shape in the tutor's stroke language, in canvas units (0…100 across,
/// 0…56 down, origin top-left like the screenshot space the tutor already uses).
enum HootNapkinPrimitive: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case ellipse(CGRect)
    case dot(CGPoint)
    /// A few words with their top-left at `topLeft`.
    case text(topLeft: CGPoint, words: String)
    /// One quadratic Bézier: start, control point, end.
    case curve(from: CGPoint, control: CGPoint, to: CGPoint)

    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

/// A primitive plus the spoken sentence it belongs to.
struct HootNapkinStroke: Equatable, Identifiable {
    /// Position in the block: strokes are drawn in this order.
    let id: Int
    /// 1-based index of the spoken sentence this stroke draws under.
    let sentenceIndex: Int
    let primitive: HootNapkinPrimitive
}

/// A parsed [NAPKIN:] block, still in canvas units.
struct HootNapkinSketch: Equatable {
    /// 16:9, small enough that integer coordinates are easy to write.
    static let canvasSize = CGSize(width: 100, height: 56)
    /// The tutor may send at most this many primitives (and this many
    /// text items among them); anything past the cap is dropped, so a
    /// runaway block never covers the screen in scribbles.
    static let maximumPrimitiveCount = 14
    static let maximumTextCount = 6
    static let maximumTextWordCount = 3
    static let maximumTextCharacterCount = 24

    let strokes: [HootNapkinStroke]
}

// MARK: - Published state (global coordinates)

/// What the overlay draws: the strokes mapped onto the user's display
/// (AppKit global coordinates, points, bottom-left origin), the paper card
/// they sit on, and where each spoken sentence starts so the overlay can
/// tell which group is being spoken from the revealed text alone.
struct HootNapkinSketchState: Equatable {
    /// Strokes in global coordinates (rect origins are bottom-left, as
    /// global rects grow upward).
    let strokes: [HootNapkinStroke]
    /// The display the napkin is on; each overlay window draws only its own.
    let displayFrame: CGRect
    /// The paper card, in global coordinates.
    let paperRectInGlobalSpace: CGRect
    /// The full spoken text and the character offset where each sentence
    /// starts (sentence k, 1-based, starts at `sentenceStartOffsets[k - 1]`).
    let spokenText: String
    let sentenceStartOffsets: [Int]
    let createdDate: Date

    /// 1-based index of the sentence being spoken, given how much of the
    /// spoken text has been revealed so far (the overlay's bubble text, which
    /// moves in step with the voice). 0 before anything is spoken.
    func sentenceIndexBeingSpoken(revealedCharacterCount: Int) -> Int {
        guard revealedCharacterCount > 0 else { return 0 }
        // A sentence has started once at least one of its characters is out.
        return sentenceStartOffsets.filter { $0 < revealedCharacterCount }.count
    }

    var sentenceCount: Int { max(sentenceStartOffsets.count, 1) }
}

// MARK: - Parsing

enum HootNapkinSketchParser {
    /// The first [NAPKIN:...] block in the reply, parsed tolerantly: spaces
    /// and decimals are fine, a stroke with no "s<k>:" prefix belongs to
    /// sentence 1, a primitive that can't be read is dropped (never the
    /// whole block), and the counts are capped. nil when there is no block
    /// or nothing in it survived.
    static func parseNapkinSketch(from responseText: String) -> HootNapkinSketch? {
        guard let blockBody = napkinBlockBody(in: responseText) else { return nil }

        var strokes: [HootNapkinStroke] = []
        var textCount = 0
        var currentSentenceIndex = 1
        for rawItem in blockBody.split(separator: ";", omittingEmptySubsequences: true) {
            var item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }

            // "s2: arrow ..." (the prefix may also stand alone: "s2:").
            if let sentencePrefix = sentencePrefix(in: item) {
                currentSentenceIndex = sentencePrefix.sentenceIndex
                item = sentencePrefix.remainder
                if item.isEmpty { continue }
            }

            guard strokes.count < HootNapkinSketch.maximumPrimitiveCount,
                  let primitive = parsePrimitive(item) else { continue }
            if primitive.isText {
                guard textCount < HootNapkinSketch.maximumTextCount else { continue }
                textCount += 1
            }
            strokes.append(HootNapkinStroke(id: strokes.count, sentenceIndex: currentSentenceIndex, primitive: primitive))
        }
        return strokes.isEmpty ? nil : HootNapkinSketch(strokes: strokes)
    }

    /// Removes every [NAPKIN:...] block so the brief is never spoken or shown.
    static func textWithoutNapkinBlocks(_ responseText: String) -> String {
        guard let regex = napkinBlockRegex else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    private static let napkinBlockRegex = try? NSRegularExpression(pattern: #"\[NAPKIN\s*:([^\]]*)\]"#, options: [.caseInsensitive])

    private static func napkinBlockBody(in responseText: String) -> String? {
        guard let regex = napkinBlockRegex,
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let bodyRange = Range(match.range(at: 1), in: responseText) else { return nil }
        let body = String(responseText[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// "s3: rect 1,2,3,4" → (3, "rect 1,2,3,4"). Also accepts "S3" and "s 3".
    private static func sentencePrefix(in item: String) -> (sentenceIndex: Int, remainder: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^[sS]\s*(\d{1,2})\s*:\s*"#),
              let match = regex.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)),
              let digitsRange = Range(match.range(at: 1), in: item),
              let wholeRange = Range(match.range, in: item),
              let sentenceIndex = Int(item[digitsRange]), sentenceIndex >= 1 else { return nil }
        return (sentenceIndex, String(item[wholeRange.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// "arrow 45,25,60,25" or "text 12,44:before". The keyword is
    /// case-insensitive; numbers may be decimals with stray spaces.
    private static func parsePrimitive(_ item: String) -> HootNapkinPrimitive? {
        let keywordEndIndex = item.firstIndex(where: { $0.isWhitespace || $0.isNumber || $0 == "-" }) ?? item.endIndex
        let keyword = item[..<keywordEndIndex].lowercased()
        let body = item[keywordEndIndex...].trimmingCharacters(in: .whitespaces)

        if keyword == "text" || keyword == "label" {
            // "x,y:words" (the words may contain further colons).
            guard let colonIndex = body.firstIndex(of: ":") else { return nil }
            let numbers = parseNumbers(String(body[..<colonIndex]))
            let words = body[body.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard numbers.count == 2, let trimmedWords = usableText(words) else { return nil }
            return .text(topLeft: clampedPoint(numbers[0], numbers[1]), words: trimmedWords)
        }

        let numbers = parseNumbers(body)
        switch keyword {
        case "line":
            guard numbers.count == 4 else { return nil }
            return .line(from: clampedPoint(numbers[0], numbers[1]), to: clampedPoint(numbers[2], numbers[3]))
        case "arrow":
            guard numbers.count == 4 else { return nil }
            return .arrow(from: clampedPoint(numbers[0], numbers[1]), to: clampedPoint(numbers[2], numbers[3]))
        case "rect", "box":
            guard numbers.count == 4, let rect = clampedRect(numbers) else { return nil }
            return .rect(rect)
        case "ellipse", "circle", "oval":
            guard numbers.count == 4, let rect = clampedRect(numbers) else { return nil }
            return .ellipse(rect)
        case "dot", "point":
            guard numbers.count == 2 else { return nil }
            return .dot(clampedPoint(numbers[0], numbers[1]))
        case "curve":
            guard numbers.count == 6 else { return nil }
            return .curve(
                from: clampedPoint(numbers[0], numbers[1]),
                control: clampedPoint(numbers[2], numbers[3]),
                to: clampedPoint(numbers[4], numbers[5])
            )
        default:
            return nil
        }
    }

    private static func parseNumbers(_ text: String) -> [Double] {
        let components = text.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // A component that isn't a number makes the whole primitive unreadable.
        return numbers.count == components.count ? numbers : []
    }

    /// At most three words and a couple dozen characters: it is a napkin,
    /// not a slide. Longer text is cut at a word rather than dropped.
    private static func usableText(_ words: String) -> String? {
        let wordList = words.split(whereSeparator: \.isWhitespace).prefix(HootNapkinSketch.maximumTextWordCount)
        var text = wordList.joined(separator: " ")
        if text.count > HootNapkinSketch.maximumTextCharacterCount {
            text = String(text.prefix(HootNapkinSketch.maximumTextCharacterCount))
        }
        return text.isEmpty ? nil : text
    }

    /// A point a little off the canvas is pulled back on, so one bad
    /// number never draws across the screen.
    private static func clampedPoint(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(
            x: min(max(x, 0), HootNapkinSketch.canvasSize.width),
            y: min(max(y, 0), HootNapkinSketch.canvasSize.height)
        )
    }

    private static func clampedRect(_ numbers: [Double]) -> CGRect? {
        guard numbers[2] > 0, numbers[3] > 0 else { return nil }
        let topLeft = clampedPoint(numbers[0], numbers[1])
        let bottomRight = clampedPoint(numbers[0] + numbers[2], numbers[1] + numbers[3])
        let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }
}

// MARK: - Sentences of the spoken text

enum HootNapkinSentences {
    /// Character offsets where each spoken sentence starts: the start of
    /// the text, then the first character after every ". ", "! " or "? ".
    /// The same rule the speech queue uses to split sentences, so "s2"
    /// means what the tutor meant.
    static func sentenceStartOffsets(in spokenText: String) -> [Int] {
        var startOffsets = [0]
        var previousCharacter: Character?
        var characterOffset = 0
        var isInsideWhitespaceRun = false
        for character in spokenText {
            if let previousCharacter, ".!?".contains(previousCharacter), character.isWhitespace {
                isInsideWhitespaceRun = true
            } else if isInsideWhitespaceRun, !character.isWhitespace {
                startOffsets.append(characterOffset)
                isInsideWhitespaceRun = false
            } else if !character.isWhitespace {
                isInsideWhitespaceRun = false
            }
            previousCharacter = character
            characterOffset += 1
        }
        return startOffsets
    }
}

// MARK: - Layout (where the paper goes)

enum HootNapkinLayout {
    /// 100×56 canvas units × 3.2 = a 320×180pt drawing.
    static let pointsPerCanvasUnit: CGFloat = 3.2
    /// Paper margin around the drawing, so strokes at the canvas edge don't
    /// touch the card edge.
    static let paperMargin: CGFloat = 8
    static var paperSize: CGSize {
        CGSize(
            width: HootNapkinSketch.canvasSize.width * pointsPerCanvasUnit + paperMargin * 2,
            height: HootNapkinSketch.canvasSize.height * pointsPerCanvasUnit + paperMargin * 2
        )
    }
    static let gapFromNeighbours: CGFloat = 16
    static let screenEdgeMargin: CGFloat = 16

    /// What the paper must stay clear of, all in global coordinates.
    struct Surroundings {
        /// The display the napkin goes on (the one hoot is on).
        let displayFrame: CGRect
        /// The part of it not under the menu bar or dock.
        let visibleFrame: CGRect
        /// The index-card frame around the pointed thing (tab room and
        /// depth edge included), when the reply points at something.
        let pointingFrameRect: CGRect?
        /// Where the cursor was; hoot sits on the cursor's side of the frame.
        let cursorLocation: CGPoint
        /// The head and the answer bubble hanging under it (an estimate:
        /// the overlay places the bubble itself, but it always hangs from
        /// the head and is at most 180pt wide).
        let headAndBubbleRect: CGRect
    }

    /// Picks the paper's place: beside the pointing frame on the side away
    /// from the cursor, else the other side, else under or over the bubble,
    /// else the bottom-left corner of the screen; the first candidate that
    /// fits on screen clear of the frame, bubble and hoot wins, otherwise
    /// the one that covers the least of them.
    static func paperRect(in surroundings: Surroundings) -> CGRect {
        let size = paperSize
        let visible = surroundings.visibleFrame.insetBy(dx: screenEdgeMargin, dy: screenEdgeMargin)
        var candidateOrigins: [CGPoint] = []

        if let frame = surroundings.pointingFrameRect {
            let isCursorLeftOfFrame = surroundings.cursorLocation.x < frame.midX
            // Global y grows upward: align the paper's top with the frame's top.
            let topAlignedY = frame.maxY - size.height
            let rightOfFrame = CGPoint(x: frame.maxX + gapFromNeighbours, y: topAlignedY)
            let leftOfFrame = CGPoint(x: frame.minX - gapFromNeighbours - size.width, y: topAlignedY)
            candidateOrigins += isCursorLeftOfFrame ? [rightOfFrame, leftOfFrame] : [leftOfFrame, rightOfFrame]
        }

        let bubble = surroundings.headAndBubbleRect
        candidateOrigins.append(CGPoint(x: bubble.minX, y: bubble.minY - gapFromNeighbours - size.height))
        candidateOrigins.append(CGPoint(x: bubble.minX, y: bubble.maxY + gapFromNeighbours))
        candidateOrigins.append(CGPoint(x: visible.minX, y: visible.minY))

        let rectsToAvoid = [surroundings.pointingFrameRect, bubble].compactMap { $0 }
        var bestRect = CGRect(origin: candidateOrigins.last ?? CGPoint(x: visible.minX, y: visible.minY), size: size)
        var smallestOverlapArea = CGFloat.greatestFiniteMagnitude
        for candidateOrigin in candidateOrigins {
            let candidateRect = clamped(CGRect(origin: candidateOrigin, size: size), to: visible)
            let overlapArea = rectsToAvoid.reduce(CGFloat(0)) { runningArea, rectToAvoid in
                let overlap = candidateRect.intersection(rectToAvoid)
                return runningArea + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            if overlapArea < smallestOverlapArea {
                smallestOverlapArea = overlapArea
                bestRect = candidateRect
            }
            if overlapArea == 0 { break }
        }
        // Whole points keep the 2pt pixels crisp.
        return CGRect(x: bestRect.minX.rounded(), y: bestRect.minY.rounded(), width: size.width, height: size.height)
    }

    /// The index-card frame's footprint (POINTING.md: box + 4pt padding,
    /// at least 28×24, a 4pt depth edge on the bottom and right, 18pt of
    /// tab room above and below) around a resolved pointing target.
    static func pointingFrameRect(centeredAt targetCenter: CGPoint, elementBoxSize: CGSize?) -> CGRect {
        let element = elementBoxSize ?? CGSize(width: 64, height: 40)
        let frameWidth = max(element.width + 8, 28)
        let frameHeight = max(element.height + 8, 24)
        return CGRect(
            x: targetCenter.x - frameWidth / 2,
            y: targetCenter.y - frameHeight / 2 - 4 - 18,
            width: frameWidth + 4,
            height: frameHeight + 4 + 18 * 2
        )
    }

    /// Where the head and its answer bubble are expected: beside the frame
    /// on the cursor's side when pointing (head at the frame's top, bubble
    /// hanging under it), else just below-right of the cursor.
    static func estimatedHeadAndBubbleRect(cursorLocation: CGPoint, pointingFrameRect: CGRect?) -> CGRect {
        let headSide: CGFloat = 24
        let bubbleWidth: CGFloat = 180
        let bubbleHeightAllowance: CGFloat = 150
        let headCenter: CGPoint
        if let frame = pointingFrameRect {
            let isCursorLeftOfFrame = cursorLocation.x < frame.midX
            headCenter = CGPoint(
                x: isCursorLeftOfFrame ? frame.minX - 10 - headSide / 2 : frame.maxX + 10 + headSide / 2,
                y: frame.maxY - 18 - 8 - headSide / 2
            )
        } else {
            headCenter = CGPoint(x: cursorLocation.x + 36, y: cursorLocation.y - 32)
        }
        // From the head's top down past the bubble; the bubble's left edge
        // is 2pt left of the head.
        return CGRect(
            x: headCenter.x - headSide / 2 - 2,
            y: headCenter.y + headSide / 2 - headSide - 8 - bubbleHeightAllowance,
            width: max(bubbleWidth, headSide) + 4,
            height: headSide + 8 + bubbleHeightAllowance
        )
    }

    /// Maps the parsed canvas onto the paper: canvas y grows downward and
    /// global y upward, so y is flipped against the drawing's top edge, and
    /// rects are re-based on their bottom-left corner.
    static func resolvedStrokes(_ sketch: HootNapkinSketch, paperRect: CGRect) -> [HootNapkinStroke] {
        let drawingTopLeft = CGPoint(x: paperRect.minX + paperMargin, y: paperRect.maxY - paperMargin)
        func globalPoint(_ canvasPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: drawingTopLeft.x + canvasPoint.x * pointsPerCanvasUnit,
                y: drawingTopLeft.y - canvasPoint.y * pointsPerCanvasUnit
            )
        }
        func globalRect(_ canvasRect: CGRect) -> CGRect {
            let bottomLeft = globalPoint(CGPoint(x: canvasRect.minX, y: canvasRect.maxY))
            return CGRect(
                origin: bottomLeft,
                size: CGSize(width: canvasRect.width * pointsPerCanvasUnit, height: canvasRect.height * pointsPerCanvasUnit)
            )
        }
        return sketch.strokes.map { stroke in
            let resolvedPrimitive: HootNapkinPrimitive
            switch stroke.primitive {
            case let .line(from, to): resolvedPrimitive = .line(from: globalPoint(from), to: globalPoint(to))
            case let .arrow(from, to): resolvedPrimitive = .arrow(from: globalPoint(from), to: globalPoint(to))
            case let .rect(rect): resolvedPrimitive = .rect(globalRect(rect))
            case let .ellipse(rect): resolvedPrimitive = .ellipse(globalRect(rect))
            case let .dot(point): resolvedPrimitive = .dot(globalPoint(point))
            case let .text(topLeft, words): resolvedPrimitive = .text(topLeft: globalPoint(topLeft), words: words)
            case let .curve(from, control, to):
                resolvedPrimitive = .curve(from: globalPoint(from), control: globalPoint(control), to: globalPoint(to))
            }
            return HootNapkinStroke(id: stroke.id, sentenceIndex: stroke.sentenceIndex, primitive: resolvedPrimitive)
        }
    }

    /// Everything together: parses the block, picks the paper's place on
    /// the display hoot is on, and maps the strokes onto it. nil when the
    /// reply has no usable block.
    static func napkinSketchState(
        fromResponseText responseText: String,
        spokenText: String,
        capturedScreens: [CapturedScreen],
        pointingLocation: HootResolvedPointingLocation?,
        cursorLocation: CGPoint = NSEvent.mouseLocation
    ) -> HootNapkinSketchState? {
        guard let sketch = HootNapkinSketchParser.parseNapkinSketch(from: responseText) else { return nil }

        // The napkin lives on the display hoot is on: the pointed one when
        // pointing, else the cursor's.
        let displayFrame = pointingLocation?.displayFrame
            ?? capturedScreens.first(where: { $0.isCursorScreen })?.displayFrame
            ?? capturedScreens.first?.displayFrame
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame == displayFrame })?.visibleFrame ?? displayFrame
        let pointingFrameRect: CGRect? = pointingLocation.map { location in
            Self.pointingFrameRect(centeredAt: location.globalLocation, elementBoxSize: location.globalBoxSize)
        }
        let surroundings = Surroundings(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            pointingFrameRect: pointingFrameRect,
            cursorLocation: cursorLocation,
            headAndBubbleRect: estimatedHeadAndBubbleRect(cursorLocation: cursorLocation, pointingFrameRect: pointingFrameRect)
        )
        let paperRect = paperRect(in: surroundings)
        let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HootNapkinSketchState(
            strokes: resolvedStrokes(sketch, paperRect: paperRect),
            displayFrame: displayFrame,
            paperRectInGlobalSpace: paperRect,
            spokenText: trimmedSpokenText,
            sentenceStartOffsets: HootNapkinSentences.sentenceStartOffsets(in: trimmedSpokenText),
            createdDate: Date()
        )
    }

    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var clampedRect = rect
        clampedRect.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        clampedRect.origin.y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
        return clampedRect
    }
}
