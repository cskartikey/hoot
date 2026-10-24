"""Template: equation steps. Each line appears under the last; the key move is highlighted."""

from manim import *
from kit import *

# Beat end times in seconds (cumulative), from the narration audio.
T = [5.5, 12.0, 19.0, 25.0]


class Explainer(Scene):
    def construct(self):
        # Beat 1 (0.0-5.5s): "We want the slope of x squared at any point."
        head = heading("The derivative of x²")
        goal = equation("f(x) = x²", size=52)
        goal.next_to(head, DOWN, buff=0.8)
        self.play(FadeIn(head, shift=DOWN * 0.2), run_time=0.8)
        self.play(Write(goal), run_time=1.2)
        wait_until(self, T[0])

        # Beat 2 (5.5-12.0s): "Nudge x by a tiny amount h and see how much f changes."
        step1 = equation("f(x+h) − f(x) = (x+h)² − x²", size=42)
        step2 = equation("= 2xh + h²", size=42, t2c={"2xh": EMBER})
        lines = VGroup(step1, step2).arrange(DOWN, buff=0.35, aligned_edge=LEFT)
        lines.next_to(goal, DOWN, buff=0.6)
        keep_in_frame(lines)
        self.play(FadeIn(step1, shift=UP * 0.2), run_time=1.0)
        self.play(FadeIn(step2, shift=UP * 0.2), run_time=1.0)
        wait_until(self, T[1])

        # Beat 3 (12.0-19.0s): "Divide by h. As h shrinks to zero, the h term vanishes."
        step3 = equation("(2xh + h²) / h = 2x + h", size=42)
        step3.next_to(lines, DOWN, buff=0.35, aligned_edge=LEFT)
        self.play(FadeIn(step3, shift=UP * 0.2), run_time=1.0)
        cross = Line(step3[-1].get_corner(DL), step3[-1].get_corner(UR)).set_stroke(RED, 5)
        note = body("h → 0", size=30, color=RED).next_to(step3, RIGHT, buff=0.5)
        self.play(Create(cross), FadeIn(note), run_time=1.0)
        wait_until(self, T[2])

        # Beat 4 (19.0-25.0s): "So the slope of x squared is two x."
        answer = equation("f′(x) = 2x", size=60, color=EMBER)
        work = VGroup(lines, step3, cross, note)
        self.play(FadeOut(work, shift=UP * 0.3), run_time=0.6)
        answer.next_to(goal, DOWN, buff=1.0)
        self.play(Write(answer), run_time=1.2)
        self.play(Create(highlight(answer, color=EMBER)), run_time=0.8)
        wait_until(self, T[3])
