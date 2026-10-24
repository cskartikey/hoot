"""Template: side by side comparison. Two columns under one heading, then a verdict."""

from manim import *
from kit import *

# Beat end times in seconds (cumulative), from the narration audio.
T = [5.0, 12.0, 19.0, 25.0]


class Explainer(Scene):
    def construct(self):
        # Beat 1 (0.0-5.0s): "Two ways to search a sorted list."
        head = heading("Linear vs binary search")
        divider = Line(UP * 2.6, DOWN * 1.2).set_stroke(LINE, 2)
        lt = title("Linear", size=36, color=BLUE).move_to([-FRAME_W / 4, 2.3, 0])
        rt = title("Binary", size=36, color=EMBER).move_to([FRAME_W / 4, 2.3, 0])
        self.play(FadeIn(head, shift=DOWN * 0.2), Create(divider), run_time=1.0)
        self.play(FadeIn(lt), FadeIn(rt), run_time=0.8)
        wait_until(self, T[0])

        # Beat 2 (5.0-12.0s): "Linear search checks every item, one by one."
        cells_l = VGroup(*[box(str(n), BLUE, width=0.7, height=0.7, size=24) for n in range(1, 9)])
        cells_l.arrange(RIGHT, buff=0.08)
        left_half(cells_l, y=0.8)
        self.play(LaggedStart(*[FadeIn(c) for c in cells_l], lag_ratio=0.1), run_time=1.0)
        for c in cells_l[:7]:
            self.play(c.rect.animate.set_fill(BLUE, 0.6), run_time=0.25)
        cost_l = equation("8 items → up to 8 checks", size=28, color=BLUE)
        left_half(cost_l, y=-0.6)
        self.play(FadeIn(cost_l), run_time=0.6)
        wait_until(self, T[1])

        # Beat 3 (12.0-19.0s): "Binary search halves the list each time."
        cells_r = VGroup(*[box(str(n), EMBER, width=0.7, height=0.7, size=24) for n in range(1, 9)])
        cells_r.arrange(RIGHT, buff=0.08)
        right_half(cells_r, y=0.8)
        self.play(LaggedStart(*[FadeIn(c) for c in cells_r], lag_ratio=0.1), run_time=1.0)
        self.play(cells_r[:4].animate.set_opacity(0.2), run_time=0.6)
        self.play(cells_r[4:6].animate.set_opacity(0.2), run_time=0.6)
        self.play(cells_r[6].animate.set_opacity(0.2), Indicate(cells_r[7], color=GOLD), run_time=0.8)
        cost_r = equation("8 items → 3 checks (log₂ 8)", size=28, color=EMBER)
        right_half(cost_r, y=-0.6)
        self.play(FadeIn(cost_r), run_time=0.6)
        wait_until(self, T[2])

        # Beat 4 (19.0-25.0s): "With a million items, that's twenty checks instead of a million."
        bars = bar_compare([("linear", 1000000), ("binary", 20)], max_height=1.4, bar_width=1.2,
                           gap=1.4, colors=[BLUE, EMBER])
        bars.move_to(DOWN * 2.45)
        keep_in_frame(bars)
        self.play(*[GrowFromEdge(b, DOWN) for b in bars.bars], FadeIn(bars.base), FadeIn(bars.labels),
                  FadeIn(bars.values), run_time=1.5)
        wait_until(self, T[3])
