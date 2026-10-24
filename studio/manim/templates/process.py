"""Template: process / algorithm. Boxes and arrows built up step by step, then a token moves through."""

from manim import *
from kit import *

# Beat end times in seconds (cumulative), from the narration audio.
T = [5.0, 12.0, 19.0, 26.0]


class Explainer(Scene):
    def construct(self):
        # Beat 1 (0.0-5.0s): "A request goes through three stages."
        head = heading("How a request flows")
        stages = VGroup(
            box("Browser", BLUE),
            box("Server", EMBER),
            box("Database", TEAL),
        ).arrange(RIGHT, buff=2.4)
        fit(stages, SAFE_W, 2.0).move_to(UP * 1.2)
        self.play(FadeIn(head, shift=DOWN * 0.2), run_time=0.8)
        self.play(LaggedStart(*[FadeIn(s, shift=UP * 0.3) for s in stages], lag_ratio=0.3), run_time=1.5)
        wait_until(self, T[0])

        # Beat 2 (5.0-12.0s): "The browser asks the server, and the server asks the database."
        a1 = arrow_between(stages[0], stages[1], color=MUTED, label="GET /user")
        a2 = arrow_between(stages[1], stages[2], color=MUTED, label="SELECT")
        self.play(GrowArrow(a1.arrow), FadeIn(a1.label), run_time=1.0)
        self.play(GrowArrow(a2.arrow), FadeIn(a2.label), run_time=1.0)
        token = glow_dot(stages[0].get_center(), color=GOLD)
        self.play(FadeIn(token), run_time=0.4)
        self.play(token.animate.move_to(stages[1].get_center()), run_time=1.0, rate_func=smooth)
        self.play(token.animate.move_to(stages[2].get_center()), run_time=1.0, rate_func=smooth)
        wait_until(self, T[1])

        # Beat 3 (12.0-19.0s): "The answer travels back the same way."
        # Route the reply under the boxes: bottom edge to bottom edge, curved.
        back = arrow_between(stages[2].get_bottom(), stages[0].get_bottom(), color=EMBER,
                             label="200 OK", curved=-1.0)
        self.play(Create(back.arrow), FadeIn(back.label), run_time=1.2)
        self.play(MoveAlongPath(token, back.arrow.copy()), run_time=1.6, rate_func=smooth)
        wait_until(self, T[2])

        # Beat 4 (19.0-26.0s): "Each hop adds a little delay."
        steps = step_list(["browser → server", "server → database", "and back again"], size=28)
        steps.next_to(back, DOWN, buff=0.3)
        keep_in_frame(steps)
        for r in steps:
            self.play(FadeIn(r, shift=RIGHT * 0.2), run_time=0.6)
        self.play(Indicate(stages[1], color=GOLD), run_time=1.0)
        wait_until(self, T[3])
