"""Template: geometry / linear algebra. A grid, a unit square, a matrix applied to the plane."""

from manim import *
from kit import *

# Beat end times in seconds (cumulative), from the narration audio.
T = [5.0, 12.0, 19.0, 26.0]


class Explainer(Scene):
    def construct(self):
        # Beat 1 (0.0-5.0s): "Start with a flat grid and one unit square."
        plane = grid(x_range=(-7, 7, 1), y_range=(-4, 4, 1))
        square = Square(side_length=1).set_fill(EMBER, 0.45).set_stroke(EMBER, 3)
        square.move_to(plane.c2p(0.5, 0.5))
        head = heading("What a matrix does to area")
        head.add_background_rectangle(color=BG, opacity=0.85, buff=0.15)
        self.play(Create(plane), run_time=1.5)
        self.play(FadeIn(head, shift=DOWN * 0.2), DrawBorderThenFill(square), run_time=1.2)
        area = label_at(square, "area = 1", direction=RIGHT, color=EMBER)
        area.add_background_rectangle(color=BG, opacity=0.85, buff=0.08)
        self.play(FadeIn(area), run_time=0.6)
        wait_until(self, T[0])

        # Beat 2 (5.0-12.0s): "Apply a matrix and every grid line moves with it."
        m = [[2, 1], [0, 1]]
        mat = matrix(m, size=34).to_corner(UL, buff=0.5).shift(DOWN * 0.9)
        mat_bg = BackgroundRectangle(mat, color=BG, fill_opacity=0.9, buff=0.15)
        self.play(FadeIn(mat_bg), Write(mat), FadeOut(area), run_time=1.0)
        self.play(ApplyMatrix(m, plane), ApplyMatrix(m, square), run_time=3.0, rate_func=smooth)
        wait_until(self, T[1])

        # Beat 3 (12.0-19.0s): "The square became a parallelogram with area two."
        new_area = label_at(square, "area = 2", direction=RIGHT, color=EMBER)
        new_area.add_background_rectangle(color=BG, opacity=0.85, buff=0.08)
        self.play(Indicate(square, color=GOLD), FadeIn(new_area), run_time=1.5)
        det = equation("det = 2·1 − 1·0 = 2", size=36, t2c={"= 2": EMBER}).next_to(mat, DOWN, buff=0.4, aligned_edge=LEFT)
        det.add_background_rectangle(color=BG, opacity=0.9, buff=0.1)
        self.play(Write(det), run_time=1.5)
        wait_until(self, T[2])

        # Beat 4 (19.0-26.0s): "That stretch factor is the determinant."
        box_ = highlight(det, color=GOLD)
        self.play(Create(box_), run_time=0.8)
        self.play(Circumscribe(square, color=EMBER), run_time=1.5)
        wait_until(self, T[3])
