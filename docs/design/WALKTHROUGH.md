# Walkthrough — multi-step pointing on the 1b frame

Extends `POINTING.md` (index-card frame + tab). Same `PetPointingFrameView`, same tab, same tokens (`README.md`). Nothing new is drawn outside the frame, its tab and hoot's head. Design: `wait what Walkthrough.dc.html` (2a live loop with tweaks, 2b annotated Google Docs share walkthrough, 2c tab states, 2d move, 2e after the last sentence). Scene component: `WalkScene.dc.html`.

All timings are **stepped** (`steps`, no easing, no tween between steps). "N steps over T" = N discrete states, each held T/N.

## Model

The tutor returns 2–5 steps, one per spoken sentence:

```
[STEP 1/3 POINT:x,y,w,h:share] click share.
[STEP 2/3 POINT:x,y,w,h:access] then switch this to anyone with the link.
[STEP 3/3 POINT:x,y,w,h:copy link] then copy link.
```

- One frame instance for the whole walkthrough. It's created at step 1 and moves; never two frames on screen.
- Steps advance on **sentence boundaries** of TTS (not on learner clicks).
- After the last sentence: **waiting** (≈4000ms) → **peek** → **checking** → **done** or **still this one**.
- `label` per step = the tutor's short label (same rules as `POINTING.md`: lowercase, `nil`/`"none"` → no label, badge still shows).

## 1. Step badge in the tab

Tab geometry, shape, font, flip-below rule: unchanged from `POINTING.md`. Content changes:

| state | tab text | tone |
|---|---|---|
| step | `1 of 3 · share` | `accent` |
| in transit (2d) | `2 of 3` (badge only) | `accent` |
| waiting | `your turn` + 3 dots | `accent` |
| checking | `checking` + 3 dots | `accent` |
| done | pixel check + `done` | `accent2` |
| missed step | `still this one · access` | `accent` |

- Text: JetBrains Mono 10.5 / semibold, `onAccent`, **tabular numerals** (`.monospacedDigit()`; JBM is monospaced anyway) so `1 of 3` → `2 of 3` never shifts the label. Separator ` · ` (space, U+00B7, space), same weight and color — no second color in the tab.
- Width ≈ chars × 6.3 + 14 (padding 7/7). Reference widths: `1 of 3 · share` 102, `2 of 3 · access` 109, `3 of 3 · copy link` 127, `3 of 5 · anyone with the link` 197 (longest realistic), `2 of 3` 52, `your turn ···` 85, `checking ···` 78, `✓ done` 57, `still this one · access` 159.
- Max width during a walkthrough: `max(frame.w − 16, 220)`. Over the cap the **label** truncates its tail with `…`; the badge never truncates. (Walkthrough targets are buttons, usually narrower than their tab, so the `frame.w − 16` cap alone would truncate everything.)
- Overhang: a tab wider than the frame overhangs to the **right** (as today). New: if `tab.maxX > screen.maxX − 8`, mirror it — right edge at `frame.w − 8`, overhanging left. (2b beat 1: share button at the top-right of the window.)
- Dots: three 2×2 squares, 2pt apart, bottom-aligned with the text baseline area (top 4pt inside the 8pt slot), gap 4 after the word. Lit = `onAccent`, unlit = `onAccent @ 0.35`.
- Pixel check: 7 cells of 2×2 on a 14×10 box, gap 4 before `done`. Cells (col,row): (0,2) (1,3) (2,4) (3,3) (4,2) (5,1) (6,0). `onAccent` on the `accent2` tab.
  - Why not an `accent2` check on the `accent` tab: `#3F7FE0` on `#E5673A` is ≈1.2:1 and disappears. The whole frame turns `accent2` instead (README: `accent2` = completed), so the done mark reads as accent2 at a glance. bit's `onAccent` is `#04140A`; check + text follow `onAccent` per mascot.

## 2. Step-to-step move

**Default: slide + resize.** Same object travelling reads as "next place", not "new thing". 10 steps, 320ms, starting on the sentence boundary so the frame lands inside the first word ("then…").

| step | ms | rect | fill + depth edge | tab | head |
|---|---|---|---|---|---|
| lift 1 | 0–30 | old box | 50% | switches to new badge only (`2 of 3`) | stays, talking |
| lift 2 | 30–60 | old box | 0 (outline only) | badge | stays |
| travel 1–6 | 60–240, 30 each | `lerp(old, new, f)`, f = **0.30, 0.55, 0.75, 0.88, 0.96, 1.0** | 0 | badge, rides at frame x + 8 (or mirrored) | hops in lockstep, same f |
| land 1 | 240–280 | new box | 50% | badge + first half of label chars | landed |
| land 2 | 280–320 | new box | 100% | full | — |

- Interpolate x, y, w, h independently; **snap each to 2pt** (`(v/2).rounded()*2`) every step so the 2pt pixels stay on grid.
- The front-loaded fractions give a stepped ease-out (big jumps first, small settles) without a curve.
- No dotted trail during the slide (that's for hoot's free flight only).
- Tab flip (above ↔ below) or mirror (left ↔ right overhang) is evaluated for the **new** box at land 1 and switches in that one step; during travel the tab keeps the old side.

**Fallback: fade out + redraw** when the box centers are **> 480pt** apart, on another display, or the new box is offscreen-then-scrolled:
1. Out: frame + tab opacity → 0 in 3 steps over 150ms (existing out).
2. Hoot flies with the existing bezier arc + dotted trail to the new anchor.
3. In: existing draw-in, 8 steps over 240ms clockwise; tab shows the full `n of N · label` and rises 4 → 0 in 2 steps at 160ms.

**Head placement during a walkthrough**
- Anchor unchanged: head top = frame top + 8; 10pt outside the frame (past the depth edge), facing the frame.
- **Side is chosen once, at step 1** (cursor's side, fall back if it doesn't fit) and **locked** for all steps. Re-flip only if the locked side doesn't fit the new box; the flip happens at land 1 with scaleX in the same step. This stops the head from ping-ponging as the learner's cursor moves around.
- Head keeps its `talking` state through the move (it's mid-sentence); `idle` in the gap between sentences.

**Reduce Motion:** no travel. Old frame opacity → 0 in 60ms, new frame appears at full in 120ms (no draw-in), head jumps.

## 3. Done / still this one

**Peek** (end of waiting, ≈4000ms after the last sentence ends; or 300ms after a click inside the last box, whichever is first):
- 240ms. Head `peek`: tufts up, look down 120ms, look up 120ms.
- Fill flashes once to `accent @ 0.20` light / `@ 0.35` dark for 60ms (1 step), then 0. That's the "i'm looking now" shutter. Take the screenshot after this flash so it isn't in the image (or exclude the overlay window from capture as today).
- Then **checking** until the verdict: tab `checking` + dots stepping every **200ms** (faster than waiting), head `thinking`.

**Done** (verdict = all steps complete):
1. t 0: **hard cut** (1 step) of stroke, fill, depth edge and tab from `accent` → `accent2`, same alphas (fill 0.08 / 0.14, depth 0.35 / 0.45). Fill returns to its normal level in this same step.
2. Check draws in 3 steps × 40ms: cells 1–2, 1–4, 1–7. `done` text present from t 0.
3. Head `happy` (eyes `^ ^`, one 2pt hop: up 160ms, down).
4. Hold until t 1000. Optional one-line confirmation in TTS ("nice — link's copied.") plays alongside; don't extend the hold for it.
5. Out: 3 steps over 150ms (existing). Head returns to `idle` / cursor-follow.

The frame stays on the **last** step's box for done.

**Still this one** (verdict = step k missing; if several, the earliest):
1. Frame moves to step k's box with the normal move (slide, or fallback).
2. During transit the badge reads `still this one`; land → `still this one · access`.
3. Stays `accent`. No shake, no red, no extra mark — it's a gentle redo, not an error.
4. Hoot speaks one sentence about that step (`talking`), then **waiting** again.
5. Max 2 retries; after the second miss the frame goes out (150ms) and the tutor takes over in voice.

## 4. Waiting

Starts when the last sentence's TTS ends. Has to read "go ahead, i'm looking", so it keeps two slow, irregular signals alive and nothing that looks like a loader or a countdown.

**Frame** (stays on the last box)
- Fill → 0 in 2 steps over 80ms (50%, 0). The target is fully visible and nothing tints what they're about to click. Stroke and depth edge stay.
- Tab: at 80ms the text switches to `your turn` + 3 dots. Dots light one at a time, **400ms per step, 4-step loop** (0, 1, 2, 3 lit). This loop is the only frame animation.
- No pulsing, no scanning. Clicks inside the box don't change the frame (they trigger the early peek).

**Head** (`watching`)
- Backs off 6pt more (10 → 16pt from the frame) in 2 steps over 60ms (+3, +6), so it's not hovering over controls the learner is reaching for.
- Eyes follow the **learner's cursor**: pupil position recomputed every **240ms** (stepped, not continuous), quantised to the head sprite's pupil cells (left/right × up/down relative to the head center).
- Blink: 1000 + 870 open, 130 closed (2000ms cycle). No bob — attention, not idle.
- Cursor inside the framed box → `watchingIn` (tufts up, same blink); leaves → `watching`. Switch on the next 240ms tick.
- Mouth closed; no TTS.

## Sprites (head, 12×12 at 2×)

Added to `HEAD_STATES` in `pets.js` (mock source of truth; export into the head sprite set):

| state | frames |
|---|---|
| `watching` | look ↘ 1000 · look ↘ 870 · eyes closed 130 (live: look follows cursor) |
| `watchingIn` | same, with `alert` tufts |
| `peek` | alert + look down 120 · alert + look up 120 |
| `happy` | eyes `happy` 160 · happy + bob 160 · happy 680 |

`eyes: 'happy'`: pupil color on row 6 of both eyes, face color on row 7 (closed eye raised = smile-eyes).

## Timeline (2a loop, outcome done)

| t (ms) | event |
|---|---|
| 0 | step 1 draws in; "click share." |
| 1300 | learner clicks share, dialog opens |
| 1600 | move → access; "then switch this to anyone with the link." |
| 3800 | learner switches access |
| 4200 | move → copy link; "then copy link." |
| 5600 | waiting |
| 8400 | learner clicks copy link (in-app: peek would start at 8700) |
| 9600 | peek (mock holds the full 4s) |
| 9840 | checking |
| 10800 | done; out at 11800–11950 |

## SwiftUI notes

```swift
enum WalkthroughPhase { case step(Int, of: Int), transit(Int, of: Int), waiting, peek, checking, done, missed(Int) }

struct PointingTabContent { var badge: String?; var label: String?; var dots: Int?; var check: Int? }
```

- `PetPointingFrameView` gains `tone: Tone` (`.accent` / `.accent2`), `fillLevel: CGFloat` (0, 0.5, 1, flash), `depthLevel: CGFloat`, `tab: PointingTabContent`. Everything else unchanged.
- The coordinator owns one `Timer` at the step rate (30 / 40ms) and publishes the stepped rect; don't use `withAnimation` for any of this.
- Store the locked head side on the walkthrough (`headSide: Edge`), not per pointing target.
- Accessibility: post `NSAccessibility.announcement` with "step 2 of 3, access" on each land; "done" on done.

## Open question

Step 2's target (the access menu) only exists after step 1 is clicked. This spec advances on speech as asked; if the target isn't on screen when its sentence starts, the tutor's box will be stale. Options: hold the frame at step N in a short waiting state until the screen changes, or have the tutor re-point after a fresh screenshot. Not designed here.
