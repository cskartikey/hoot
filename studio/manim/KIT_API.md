# kit.py API (import with `from manim import *` then `from kit import *`)

Frame: 1280x720, 16:9. Scene units: x from -7.1 to 7.1, y from -4 to 4. Keep everything inside
x ∈ [-6.5, 6.5], y ∈ [-3.6, 3.6]. Headings sit at y = 3.4 (`TOP_Y`). Background is dark (`BG`).

## No LaTeX
LaTeX is NOT installed. Never use `MathTex`, `Tex`, `Matrix`, `DecimalNumber`, `Integer`,
`include_numbers=True`, `add_coordinates()`, `BraceLabel`, or `Brace.get_tex()`. Write math as
Unicode text with `equation()`: `x²`, `√2`, `∫ f(x) dx`, `θ`, `π`, `Σ`, `→`, `≤`, `≈`, `·`, `×`,
`Δ`, `∂`, `∇`, `ŷ`, subscripts `x₁ x₂ aᵢ`. `equation()` also converts simple LaTeX-ish input
(`x^2`, `\theta`, `\frac{a}{b}` → `a/b`). `Brace(mob, DOWN)` itself is fine; label it with `label_at`.
(As a safety net the kit swaps MathTex/Tex/DecimalNumber/Integer for Text-based versions, so a stray
one renders, but it looks plainer than `equation()` and the kit helpers.) To show a
changing number, `Transform` one `mono(...)` into the next.

## Palette (hex strings, same as the hoot app)
`BG` #161617 background, `BG2` card fill, `LINE` dividers / grid, `INK` #F2F2F7 main text, `MUTED`
#98989D secondary text. Accents: `EMBER` #E5673A the key idea / the answer (use most), `BLUE`
#3F7FE0 the second object, `TEAL` and `VIOLET` for other objects, `GOLD` for highlights, `RED` for
errors / the "wrong" side. `ACCENT` = EMBER, `ACCENT2` = BLUE, `ACCENTS` = list of the six colours.
Rate functions: `smooth`, `out`, `snap`.

## Fonts
Titles and body use the system sans (Helvetica Neue); `mono` and all tick numbers use JetBrains
Mono. If a mono string trips Manim's glyph count (ligatures like `==`), the kit redraws it in Menlo.

## Text (all return Text; size is font_size)
- `title(text, size=56, color=INK)`: bold sans.
- `body(text, size=32, color=INK)`: sentences. Use `\n` to break lines; ≤ 40 chars per line.
- `mono(text, size=28, color=INK)`: code, numbers.
- `equation(text, size=48, color=INK, t2c={"x²": EMBER})`: math as Unicode. Alias `eq`.
- `heading(text, size=44)`: title already placed at the top of the frame.
- `title_card(text, subtitle=None)`: centered title + short ember bar (+ muted subtitle). VGroup.
- `label_at(target, text, direction=UP, color=INK, size=28)`: label next to a mobject or point,
  kept inside the frame.

## Layout
- `fit(mob, max_w=SAFE_W, max_h=SAFE_H)`: scale down to fit. Returns mob.
- `keep_in_frame(mob)`: shift/shrink so it is fully on screen. Returns mob.
- `stack(*mobs, buff=0.3)`: column VGroup. `row(*mobs, buff=0.6)`: row VGroup.
- `left_half(mob, y=-0.3)`, `right_half(mob, y=-0.3)`: fit and center in that half (for comparisons).
- Constants: `FRAME_W` 14.22, `FRAME_H` 8, `SAFE_W` 13, `SAFE_H` 6.8, `TOP_Y` 3.4, `BOTTOM_Y` -3.4.

## Diagrams
- `box(text, color=EMBER, width=None, height=1.0, size=30)`: rounded box with label. `.rect`, `.label`.
- `arrow_between(a, b, color=MUTED, label=None, curved=0.0)`: arrow edge-to-edge between mobjects
  or points; `curved` is an arc angle like 0.8 or -1.2. Returns VGroup; `.arrow` (animate with
  `GrowArrow(g.arrow)` or `Create(g.arrow)`), `.label` if given (placed beside the arrow, clear of
  both ends; leave about 2 units between boxes that have a labelled arrow).
- `highlight(mob, color=GOLD)`: rounded outline around mob (`Create(highlight(x))`).
- `underline(mob, color=EMBER)`: line under mob.
- `glow_dot(point, color=EMBER)`: dot with halo (a moving token / packet / pointer).
- `glow(stroked_mob, color=EMBER)`: soft bloom copy to put behind a line or curve.
- `step_list(["first", "second"], size=30, numbered=True)`: VGroup of rows (marker + text);
  reveal with `FadeIn(rows[i], shift=RIGHT*0.2)`.
- `code_block(src, size=22)`: syntax-coloured code on a card. `.lines[i]` is line i, `.card`.
  `highlight_line(code, i, color=EMBER)`: translucent bar for line i. It always draws between the
  card and the text (z-index), so just `FadeIn(bar)`; move it with
  `bar.animate.move_to(highlight_line(code, j))`.

## Math objects
- `grid(x_range=(-7,7,1), y_range=(-4,4,1), unit=1.0)`: styled NumberPlane. Works with
  `ApplyMatrix([[a,b],[c,d]], plane)`; `plane.c2p(x, y)` converts coordinates to points.
  Apply the same matrix to shapes drawn on it: `ApplyMatrix(m, square)` (matrix is about the
  origin, so draw shapes in plane coordinates with the plane centered at ORIGIN, unit=1).
- `vector(end, color=EMBER, start=(0,0), plane=None)`: arrow; with `plane`, coordinates are plane units.
- `axes(x_range=(-1,6,1), y_range=(-1,4,1), width=8, height=5, x_label=None, y_label=None)`:
  Axes with Text tick numbers. Returns VGroup; use `.ax` for `ax.plot(lambda x: ..., color=EMBER)`,
  `ax.c2p(x, y)`, `ax.get_graph_label` is NOT available (use `label_at`).
- `number_line(x_range=(-5,5,1), length=10)`: VGroup; `.line.n2p(x)` gives the point for x.
- `matrix([[2,1],[0,3]], size=36)`: bracketed matrix of Text. `.entries[r][c]` is one entry.
- `bar_compare([("label", value), ...], max_height=4, bar_width=1, colors=None)`: bar chart;
  `.bars` (animate with `GrowFromEdge(bar, DOWN)`), `.labels`, `.values`, `.base`.

## Timing
- `wait_until(self, t)`: pad with `self.wait` until the scene clock reaches t seconds. Call it at
  the end of EVERY beat with that beat's end time (`T[i]`). It never shortens anything, so the
  animations inside a beat must fit in the beat.
- `budget(self, t, fraction=1.0)`: seconds left until t, use as a run_time.

Standard Manim CE also works: `Circle`, `Square`, `Rectangle`, `RoundedRectangle`, `Polygon`,
`Line`, `DashedLine`, `Arrow`, `Dot`, `Arc`, `VGroup`, `ValueTracker`, `always_redraw`,
`FadeIn`, `FadeOut`, `Create`, `Write`, `Transform`, `ReplacementTransform`, `FadeTransform`,
`Indicate`, `Circumscribe`, `LaggedStart`, `MoveAlongPath`, `GrowArrow`, `GrowFromCenter`,
`GrowFromEdge`, `Rotate`, `ApplyMatrix`, `.animate`.
