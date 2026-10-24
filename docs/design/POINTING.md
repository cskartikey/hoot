# Pointing frame — 1b "index-card frame + tab"

Replaces `PetPointingRingView` (rounded 64×40 ring + halo) and `PetPointingLabelChipView` (chip beside the head). Design: `wait what Pointing.dc.html` → 1b.

## Geometry (pt)

Box = tutor's `[POINT:x,y,w,h]` box (`detectedElementBoxSize`) **+ 4pt padding each side**.
- Min box 28×24 (after padding). Max = screen minus 8pt margin.
- Fallback when the tutor sent only `x,y`: 64×40 centered on the point.

Layers, outside → in (frame origin = padded box top-left):

| piece | rect | color |
|---|---|---|
| depth edge, bottom | x 4 → w+2, y h+2, h 2 | accent @ 0.35 light / 0.45 dark |
| depth edge, right | x w+2, y 4 → h+2, w 2 | same |
| frame top / bottom | x 2 → w-2, 2pt tall, at y 0 and y h-2 | accent |
| frame left / right | y 2 → h-2, 2pt wide, at x 0 and x w-2 | accent |
| corners | 2×2 left empty (1-pixel notch) | — |
| fill | inset 2pt | accent @ 0.08 light / 0.14 dark |
| tab | see below | accent |

No corner radius, no blur, no shadow. Snap the frame origin to whole points (`.rounded()`), so 2pt pixels stay crisp on 1× displays.

## Tab (label)

- Position: left edge 8pt in from the frame's left; top 16pt above the frame top; height 18pt (the bottom 2pt overlaps the frame's top edge so the tab grows out of it).
- Shape: rectangle with 2×2 notches on the **top** corners only (bottom corners square, merging into the frame).
- Text: JetBrains Mono 10.5 / semibold, `onAccent`, lowercase, 1 line, padding 0 / 7 (bottom padding 2 so text centers on the visible 16pt).
- Max width: frame width − 16; truncate tail. If the frame is narrower than the tab, the tab may overhang to the right (never left of the frame).
- Flip: if `frame.minY − 16 < 8` (screen top), hang the tab **below** the frame instead: top = h − 2, notches on the bottom corners.
- No usable label (`nil`, empty, `"none"`): no tab.

## Hoot placement

Head (24pt) beside the frame, vertically at frame top + 8, horizontally 10pt outside the frame (past the depth edge) on the side nearer the cursor, facing the frame. Fall back to the other side if it doesn't fit; replaces `ringHalfWidth` math in `flyToPointingTarget`.

## Motion

- In (after hoot lands): frame draws clockwise from top-left in **8 steps over 240ms** (no easing, `steps`). Fill fades 0 → final in the same 240ms. Tab rises 4pt → 0 in 2 steps, 80ms, starting at 160ms.
- Hold: static. No pulsing.
- Out: whole frame + tab opacity → 0 in 3 steps over 150ms when pointing ends.
- Reduce Motion: skip the draw, 120ms fade.

## SwiftUI sketch

```swift
struct PetPointingFrameView: View {
    let boxSize: CGSize          // padded, clamped
    let label: String?
    let drawProgress: CGFloat    // 0…1, stepped by the coordinator (8 steps)
    let tabBelow: Bool
    let theme: WaitWhatTheme

    var body: some View {
        let w = boxSize.width, h = boxSize.height
        let depth = theme.accent.opacity(theme.isDark ? 0.45 : 0.35)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(depth).frame(width: w - 2, height: 2).offset(x: 4, y: h + 2)
            Rectangle().fill(depth).frame(width: 2, height: h - 2).offset(x: w + 2, y: 4)
            Rectangle().fill(theme.accent.opacity(theme.isDark ? 0.14 : 0.08))
                .frame(width: w - 4, height: h - 4).offset(x: 2, y: 2)
            NotchedFrameShape(trim: drawProgress)
                .fill(theme.accent)
                .frame(width: w, height: h)
            if let label { PointingTab(label: label, maxWidth: w - 16, below: tabBelow, theme: theme)
                .offset(x: 8, y: tabBelow ? h - 2 : -16) }
        }
        .frame(width: w + 4, height: h + 4, alignment: .topLeading)
        .drawingGroup()           // keeps the 2pt pixels crisp
    }
}
```

`NotchedFrameShape` = the four 2pt edge rects as one `Path`, revealed clockwise by `trim` (top, right, bottom, left — 2 steps each).

## Coordinator changes

1. Publish `pointingBoxSizeInGlobalSpace: CGSize?` from `hootController.detectedElementBoxSize` (+8 for padding, clamped); clear it with `pointingTargetInGlobalSpace`.
2. `flyToPointingTarget`: use `boxSize.width / 2 + 4` (half-width + depth edge) instead of `PetPointingRingView.targetBoxSize.width / 2`; gap to head = 10.
3. `pointingRing()` in `PetOverlayScreenView` → `pointingFrame()`; inset check uses `boxSize + 24`.
4. Drop `pointingLabelChip(...)` — the label now lives in the tab.
