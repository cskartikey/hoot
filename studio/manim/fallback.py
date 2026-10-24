"""Fallback scene: shows each beat's narration as animated text, timed to the audio. Must never fail.

Reads STUDIO_BEATS: path to JSON {"title": str, "beats": [{"narration": str, "visual": str, "end": float}]}
where "end" is the cumulative end time of each beat in seconds.
"""

import json
import os
import textwrap

from manim import *
from kit import *


def _load():
    try:
        with open(os.environ["STUDIO_BEATS"]) as f:
            data = json.load(f)
        beats = [b for b in data.get("beats", []) if isinstance(b, dict)]
        return str(data.get("title") or ""), beats
    except Exception:
        return "", []


def _wrap(s: str, width: int = 34, max_lines: int = 5) -> str:
    lines = textwrap.wrap(" ".join(str(s).split()), width=width) or [" "]
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1].rstrip(".,;: ") + "…"
    return "\n".join(lines)


class Explainer(Scene):
    def construct(self):
        title_text, beats = _load()
        head = None
        if title_text:
            try:
                head = heading(title_text, size=40, color=EMBER)
                self.play(FadeIn(head, shift=DOWN * 0.2), run_time=0.6)
            except Exception:
                head = None
        prev = None
        dots = None
        try:
            if beats:
                dots = VGroup(*[Dot(radius=0.07, color=LINE) for _ in beats]).arrange(RIGHT, buff=0.25)
                dots.move_to([0, -3.4, 0])
                self.add(dots)
        except Exception:
            dots = None
        for i, b in enumerate(beats):
            end = float(b.get("end", 0) or 0)
            try:
                txt = body(_wrap(b.get("narration", "")), size=40, color=INK)
                fit(txt, SAFE_W - 1, 4.6)
                txt.move_to(DOWN * 0.2)
                bar = Line(UP * 0.5, DOWN * 0.5).set_stroke(ACCENTS[i % len(ACCENTS)], 8)
                bar.stretch_to_fit_height(txt.height + 0.2).next_to(txt, LEFT, buff=0.4)
                card = VGroup(bar, txt)
                anims = [FadeIn(card, shift=UP * 0.3)]
                if prev is not None:
                    anims.insert(0, FadeOut(prev, shift=UP * 0.3))
                if dots is not None:
                    anims.append(dots[i].animate.set_color(EMBER).scale(1.4))
                self.play(*anims, run_time=0.7)
                prev = card
            except Exception:
                pass
            try:
                wait_until(self, end)
            except Exception:
                pass
        if not beats:
            self.wait(1)
