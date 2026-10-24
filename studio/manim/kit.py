"""hoot studio kit: the house style for explainer scenes, written at Cal Hacks 13.0.

16:9, 1280x720, dark warm-grey background with ember and blue accents (the same palette as the
hoot app). Labels and code use JetBrains Mono (bundled in ./fonts); titles and body use the
macOS system sans.

There is no LaTeX on the render machine. All math is Unicode text, and importing this module
replaces Manim's MathTex / Tex / DecimalNumber / Integer with Text-based versions, so library
code (and stray model code) that reaches for them still renders.

    from manim import *
    from kit import *
"""

from __future__ import annotations

import inspect
import json
import os
import re
import sys
from pathlib import Path

import manimpango
import numpy as np
from manim import (
    DOWN,
    LEFT,
    ORIGIN,
    RIGHT,
    UP,
    Arrow,
    Axes,
    Circle,
    Dot,
    Line,
    NumberLine,
    NumberPlane,
    Rectangle,
    RoundedRectangle,
    Text,
    VGroup,
    VMobject,
    config,
    rate_functions,
)

# =============================================================================================
# Fonts

_FONT_DIR = Path(__file__).resolve().parent / "fonts"
for _f in sorted(_FONT_DIR.glob("*.ttf")):
    manimpango.register_font(str(_f))


def _pick_font(candidates: list[str]) -> str:
    try:
        installed = set(manimpango.list_fonts())
    except Exception:
        installed = set()
    for name in candidates:
        if name in installed:
            return name
    return candidates[-1]


SANS = _pick_font(["Helvetica Neue", "Helvetica", "Avenir Next", "sans-serif"])
MONO = "JetBrains Mono"
MONO_SAFE = "Menlo"  # no ligatures; used when JetBrains Mono's "==" / "->" glyphs confuse Manim

# =============================================================================================
# Frame

config.pixel_width = 1280
config.pixel_height = 720
config.frame_rate = 30
config.frame_height = 8.0
config.frame_width = 8.0 * 16 / 9

FRAME_W = config.frame_width   # ~14.22
FRAME_H = config.frame_height  # 8.0
SAFE_W = 13.0
SAFE_H = 6.8
TOP_Y = 3.4
BOTTOM_Y = -3.4

# =============================================================================================
# Palette

BG = "#161617"      # background
BG2 = "#222224"     # cards, boxes
LINE = "#3A3A3D"    # grid lines, dividers
INK = "#F2F2F7"     # main text
MUTED = "#98989D"   # secondary text

EMBER = "#E5673A"   # the key idea / the answer (use most)
BLUE = "#3F7FE0"    # second object, inputs
TEAL = "#2FB5A3"    # third object, outputs
VIOLET = "#9A7BEA"  # fourth object
GOLD = "#F2C14E"    # highlights, emphasis
RED = "#EF4F5F"     # errors, the "wrong" side
ACCENT = EMBER
ACCENT2 = BLUE
ACCENTS = [EMBER, BLUE, TEAL, VIOLET, GOLD, RED]

config.background_color = BG

smooth = rate_functions.smooth
out = rate_functions.ease_out_cubic
snap = rate_functions.ease_out_back

# =============================================================================================
# Unicode math: turns simple LaTeX-ish input into plain text

_SUPERSCRIPTS = dict(zip(
    "0123456789+-=()abcdefghijklmnoprstuvwxyzT",
    "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᵀ",
))
_SUBSCRIPTS = dict(zip(
    "0123456789+-=()aehijklmnoprstuvx",
    "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ",
))

_SYMBOLS = {
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
    "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
    "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ",
    "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ",
    "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
    "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈",
    "equiv": "≡", "sim": "∼", "propto": "∝",
    "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "implies": "⇒",
    "iff": "⇔", "mapsto": "↦",
    "infty": "∞", "partial": "∂", "nabla": "∇", "int": "∫", "iint": "∬", "oint": "∮",
    "sum": "Σ", "prod": "Π", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
    "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "emptyset": "∅", "neg": "¬",
    "land": "∧", "lor": "∨", "circ": "∘", "degree": "°", "ldots": "…", "cdots": "⋯", "dots": "…",
    "quad": "  ", "qquad": "    ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ",
    "{": "{", "}": "}", "%": "%", "$": "$", "_": "_", "&": "&", "#": "#",
}
_STYLE_WRAPPERS = {"text", "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "mathsf",
                   "operatorname", "textbf", "textit", "boldsymbol", "vec", "hat", "bar"}
_COMBINING = {"vec": "⃗", "hat": "̂", "bar": "̄"}


def _read_group(s: str, i: int) -> tuple[str, int]:
    """Read one argument at s[i]: a {braced group}, a \\command, or a single character."""
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s):
        return "", i
    if s[i] == "\\":
        m = re.match(r"\\([A-Za-z]+|.)", s[i:])
        return m.group(0), i + len(m.group(0))
    if s[i] != "{":
        return s[i], i + 1
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
    return s[i + 1:], len(s)


def _script(text: str, table: dict, marker: str) -> str:
    if text and all(c in table for c in text):
        return "".join(table[c] for c in text)
    return f"{marker}({text})" if len(text) > 1 else f"{marker}{text}"


def _atom(t: str) -> str:
    """Wrap in parentheses unless it is a single token."""
    return t if re.fullmatch(r"√?[\w.′⁰¹²³⁴⁵⁶⁷⁸⁹]+", t) else f"({t})"


def unicode_math(s: str) -> str:
    """'x^2 + \\frac{a}{b} \\le \\sqrt{y}' -> 'x² + a/b ≤ √y'. Plain Unicode passes through unchanged."""
    s = str(s).replace("$", "")
    s = re.sub(r"\\(left|right|big|Big|bigg|Bigg|displaystyle)(?![A-Za-z])", "", s)
    s = s.replace("\\\\", "\n")
    res: list[str] = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\":
            m = re.match(r"\\([A-Za-z]+|.)", s[i:])
            name = m.group(1)
            i += len(m.group(0))
            if name in ("frac", "dfrac", "tfrac"):
                num, i = _read_group(s, i)
                den, i = _read_group(s, i)
                res.append(f"{_atom(unicode_math(num))}/{_atom(unicode_math(den))}")
            elif name == "sqrt":
                if i < len(s) and s[i] == "[":
                    j = s.find("]", i)
                    i = j + 1 if j > 0 else i + 1
                arg, i = _read_group(s, i)
                res.append("√" + _atom(unicode_math(arg)))
            elif name in _STYLE_WRAPPERS:
                arg, i = _read_group(s, i)
                res.append(unicode_math(arg) + _COMBINING.get(name, ""))
            else:
                res.append(_SYMBOLS.get(name, name))
        elif c in "^_":
            arg, i = _read_group(s, i + 1)
            res.append(_script(unicode_math(arg), _SUPERSCRIPTS if c == "^" else _SUBSCRIPTS, c))
        elif c in "{}":
            i += 1
        else:
            res.append(c)
            i += 1
    return "".join(res)


# =============================================================================================
# Text


def _text(s: str, font: str, size: float, color: str, **kw) -> Text:
    s = str(s) if str(s).strip() else " "
    try:
        return Text(s, font=font, font_size=size, color=color, disable_ligatures=True, **kw)
    except ValueError:
        # Glyph count mismatch (ligatures / contextual alternates such as "=="): retry in Menlo.
        kw.pop("t2c", None)
        return Text(s, font=MONO_SAFE, font_size=size, color=color, disable_ligatures=True, **kw)


def title(text: str, size: float = 56, color: str = INK, weight: str = "BOLD") -> Text:
    """Display text in the system sans, bold."""
    return _text(text, SANS, size, color, weight=weight)


def body(text: str, size: float = 32, color: str = INK) -> Text:
    """Sentences in the system sans. Break lines with '\\n' (about 40 characters per line)."""
    return _text(text, SANS, size, color, line_spacing=0.85)


def mono(text: str, size: float = 28, color: str = INK) -> Text:
    """JetBrains Mono, for code, numbers and small labels."""
    return _text(text, MONO, size, color)


def equation(text: str, size: float = 48, color: str = INK, t2c: dict | None = None) -> Text:
    """Math as Unicode text. t2c colours substrings: equation("a² + b² = c²", t2c={"c²": EMBER})."""
    colours = {unicode_math(k): v for k, v in (t2c or {}).items()}
    return _text(unicode_math(text), SANS, size, color, t2c=colours)


eq = equation


def heading(text: str, size: float = 44, color: str = INK) -> Text:
    """Title text already placed at the top of the frame (centered at y = TOP_Y)."""
    t = title(text, size=size, color=color)
    fit(t, SAFE_W, 0.9)
    t.move_to([0, TOP_Y, 0])
    return t


def title_card(text: str, subtitle: str | None = None, color: str = INK, accent: str = EMBER) -> VGroup:
    """Centered title with a short accent bar under it and an optional muted subtitle."""
    t = fit(title(text, size=60, color=color), SAFE_W, 1.6)
    bar = Line(LEFT, RIGHT).set_stroke(accent, 6)
    bar.set_width(min(2.4, max(0.6, t.width * 0.6)))
    bar.next_to(t, DOWN, buff=0.3)
    parts = [t, bar]
    if subtitle:
        sub = fit(body(subtitle, size=32, color=MUTED), SAFE_W, 1.2)
        sub.next_to(bar, DOWN, buff=0.35)
        parts.append(sub)
    group = VGroup(*parts)
    group.move_to(ORIGIN)
    return group


def _point(x) -> np.ndarray:
    if hasattr(x, "get_center"):
        return x.get_center()
    p = list(np.array(x, dtype=float).flatten())
    return np.array((p + [0.0, 0.0, 0.0])[:3])


def label_at(target, text: str, direction=UP, color: str = INK, size: float = 28, buff: float = 0.2) -> Text:
    """A label beside a mobject (or point) in the given direction, kept on screen."""
    lab = body(text, size=size, color=color)
    lab.next_to(target if hasattr(target, "get_center") else _point(target), direction, buff=buff)
    return keep_in_frame(lab)


# =============================================================================================
# Layout


def fit(mob, max_w: float = SAFE_W, max_h: float = SAFE_H):
    """Scale mob down (never up) so it fits in max_w x max_h. Returns mob."""
    w, h = mob.width, mob.height
    factor = min(1.0, max_w / w if w > 1e-6 else 1.0, max_h / h if h > 1e-6 else 1.0)
    if factor < 1.0:
        mob.scale(factor)
    return mob


def keep_in_frame(mob, margin: float = 0.35):
    """Shrink mob if it is bigger than the visible frame, then nudge it fully on screen. Returns mob."""
    half_w = FRAME_W / 2 - margin
    half_h = FRAME_H / 2 - margin
    fit(mob, 2 * half_w, 2 * half_h)
    dx = dy = 0.0
    if mob.get_right()[0] > half_w:
        dx = half_w - mob.get_right()[0]
    elif mob.get_left()[0] < -half_w:
        dx = -half_w - mob.get_left()[0]
    if mob.get_top()[1] > half_h:
        dy = half_h - mob.get_top()[1]
    elif mob.get_bottom()[1] < -half_h:
        dy = -half_h - mob.get_bottom()[1]
    if dx or dy:
        mob.shift([dx, dy, 0])
    return mob


def stack(*mobs, buff: float = 0.3, direction=DOWN) -> VGroup:
    """Mobjects in a column (or along `direction`)."""
    return VGroup(*mobs).arrange(direction, buff=buff)


def row(*mobs, buff: float = 0.6) -> VGroup:
    """Mobjects side by side."""
    return VGroup(*mobs).arrange(RIGHT, buff=buff)


def _place_in_half(mob, sign: int, y: float):
    fit(mob, FRAME_W / 2 - 0.9, SAFE_H - 0.8)
    mob.move_to([sign * FRAME_W / 4, y, 0])
    return mob


def left_half(mob, y: float = -0.3):
    """Fit mob into the left half of the frame and center it there."""
    return _place_in_half(mob, -1, y)


def right_half(mob, y: float = -0.3):
    """Fit mob into the right half of the frame and center it there."""
    return _place_in_half(mob, 1, y)


# =============================================================================================
# Diagram pieces


class Box(VGroup):
    """Rounded card with a centered label. `.rect` and `.label`."""

    def __init__(self, text: str, color: str = EMBER, width: float | None = None, height: float = 1.0,
                 size: float = 30, fill_opacity: float = 0.14):
        super().__init__()
        self.label = body(text, size=size, color=INK)
        w = width if width is not None else max(1.6, self.label.width + 0.7)
        self.rect = RoundedRectangle(width=w, height=height, corner_radius=min(0.18, height * 0.25, w * 0.25))
        self.rect.set_fill(color, fill_opacity).set_stroke(color, 2.5)
        fit(self.label, w - 0.25, height - 0.2)
        self.label.move_to(self.rect)
        self.add(self.rect, self.label)


def box(text: str, color: str = EMBER, width: float | None = None, height: float = 1.0, size: float = 30,
        fill_opacity: float = 0.14) -> Box:
    return Box(text, color=color, width=width, height=height, size=size, fill_opacity=fill_opacity)


def _edge_toward(mob, target: np.ndarray) -> np.ndarray:
    """Where the ray from mob's center toward target leaves mob's bounding box."""
    c = mob.get_center()
    d = target - c
    if np.allclose(d[:2], 0):
        return c
    hw, hh = mob.width / 2, mob.height / 2
    tx = hw / abs(d[0]) if abs(d[0]) > 1e-9 else np.inf
    ty = hh / abs(d[1]) if abs(d[1]) > 1e-9 else np.inf
    return c + d * min(tx, ty, 1.0)


def _overlaps(m1, m2, pad: float = 0.04) -> bool:
    return not (m1.get_right()[0] < m2.get_left()[0] - pad or m1.get_left()[0] > m2.get_right()[0] + pad or
                m1.get_top()[1] < m2.get_bottom()[1] - pad or m1.get_bottom()[1] > m2.get_top()[1] + pad)


class Connector(VGroup):
    """Arrow plus optional label. `.arrow`, `.label` (None without a label)."""


def arrow_between(a, b, color: str = MUTED, label: str | None = None, buff: float = 0.15,
                  curved: float = 0.0, size: float = 24, stroke: float = 4) -> Connector:
    """Arrow from a to b (mobjects or points), edge to edge. `curved` bends it (arc angle, e.g. 0.8 / -1.2)."""
    pa, pb = _point(a), _point(b)
    start = _edge_toward(a, pb) if hasattr(a, "get_center") else pa
    end = _edge_toward(b, pa) if hasattr(b, "get_center") else pb
    d = end - start
    n = np.linalg.norm(d)
    if n > 2 * buff + 1e-3:
        start, end = start + d / n * buff, end - d / n * buff
    arr = Arrow(start, end, buff=0, color=color, stroke_width=stroke, path_arc=curved,
                max_tip_length_to_length_ratio=0.2, tip_length=0.22)
    group = Connector(arr)
    group.arrow = arr
    group.label = None
    if label:
        lab = mono(label, size=size, color=INK if color == MUTED else color)
        unit = d / (n or 1.0)
        perp = np.array([-unit[1], unit[0], 0.0])
        if abs(curved) < 1e-6:
            mid = (start + end) / 2
            away = perp if (perp[1] > 1e-6 or (abs(perp[1]) <= 1e-6 and perp[0] < 0)) else -perp
        else:
            mid = arr.point_from_proportion(0.5)
            bulge = float(np.dot(mid - (start + end) / 2, perp))  # which side the arc bows to
            away = perp if bulge >= 0 else -perp
        away = away / (np.linalg.norm(away) or 1.0)
        if abs(curved) < 1e-6 and n > 0.3:
            fit(lab, max(n - 0.1, lab.width * 0.6), 10)  # shrink a little to sit over a short arrow
        lab.move_to(mid)
        lab.shift(away * (0.16 + abs(away[0]) * lab.width / 2 + abs(away[1]) * lab.height / 2))
        ends = [m for m in (a, b) if hasattr(m, "get_center")]
        for _ in range(12):  # step away from the arrow until the label clears both endpoints
            if not any(_overlaps(lab, m) for m in ends):
                break
            lab.shift(away * 0.1)
        keep_in_frame(lab)
        group.label = lab
        group.add(lab)
    return group


def highlight(mob, color: str = GOLD, buff: float = 0.12, stroke: float = 4) -> RoundedRectangle:
    """Rounded outline around mob. Animate with Create(highlight(x))."""
    w, h = mob.width + 2 * buff, mob.height + 2 * buff
    r = RoundedRectangle(width=w, height=h, corner_radius=min(0.15, h / 4, w / 4))
    r.set_stroke(color, stroke).set_fill(opacity=0)
    return r.move_to(mob)


def underline(mob, color: str = EMBER, buff: float = 0.08, stroke: float = 4) -> Line:
    """Line just under mob, same width."""
    y = mob.get_bottom()[1] - buff
    return Line([mob.get_left()[0], y, 0], [mob.get_right()[0], y, 0]).set_stroke(color, stroke)


def glow_dot(point, color: str = EMBER, radius: float = 0.1) -> VGroup:
    """A bright dot with a soft halo, for tokens, packets and pointers."""
    p = _point(point)
    halo = VGroup(*[
        Circle(radius=radius * k).set_fill(color, 0.13).set_stroke(width=0).move_to(p)
        for k in (3.0, 2.2, 1.6)
    ])
    return VGroup(halo, Dot(p, radius=radius, color=color))


def glow(mob: VMobject, color: str = EMBER, layers: int = 5, width: float = 16, opacity: float = 0.4) -> VGroup:
    """Soft bloom for a line or curve: wider, fainter copies. Add it behind the original."""
    group = VGroup()
    for k in range(layers, 0, -1):
        c = mob.copy().clear_updaters()
        c.set_fill(opacity=0)
        c.set_stroke(color, width=width * k / layers, opacity=min(1.0, opacity * 1.5 / layers))
        group.add(c)
    return group


def step_list(items, size: float = 30, numbered: bool = True, color: str = INK, accent: str = EMBER,
              buff: float = 0.32) -> VGroup:
    """Rows of (marker, text), left aligned. Reveal with FadeIn(rows[i], shift=RIGHT*0.2)."""
    rows = VGroup()
    for i, item in enumerate(items):
        txt = body(item, size=size, color=color)
        if numbered:
            num = mono(str(i + 1), size=size * 0.7, color=BG)
            disc = Circle(radius=max(num.height, num.width) * 0.5 + 0.1).set_fill(accent, 1).set_stroke(width=0)
            num.move_to(disc)
            marker = VGroup(disc, num)
        else:
            marker = Dot(radius=0.07, color=accent)
        rows.add(VGroup(marker, txt).arrange(RIGHT, buff=0.25))
    rows.arrange(DOWN, buff=buff, aligned_edge=LEFT)
    return fit(rows, SAFE_W, SAFE_H - 1)


# ---- code ----

_KEYWORDS = set("""def return if else elif for while in import from class as with try except finally
raise lambda yield pass break continue and or not is None True False async await const let var function
new this null undefined true false struct fn pub impl match int float void char bool static public private
""".split())
_TOKEN = re.compile(r"(#.*|//.*)|(\"[^\"]*\"|'[^']*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)|(\S)")


class CodeBlock(VGroup):
    """Code on a card. `.card`, `.lines` (one Text per source line; blank lines are invisible markers)."""


def _paint_line(t: Text, line: str):
    """Colour keywords, strings, numbers and comments by walking the glyphs (one per visible char)."""
    if len(t.submobjects) != sum(1 for c in line if not c.isspace()):
        return
    idx = 0
    for m in _TOKEN.finditer(line):
        comment, string, number, word, _ = m.groups()
        colour = (MUTED if comment else TEAL if string else BLUE if number else
                  EMBER if word in _KEYWORDS else None)
        n = sum(1 for c in m.group(0) if not c.isspace())
        if colour:
            for g in t.submobjects[idx:idx + n]:
                g.set_color(colour)
        idx += n


def code_block(src: str, language: str = "python", size: float = 22) -> CodeBlock:
    """Syntax-coloured code on a card, indentation preserved."""
    src_lines = src.strip("\n").expandtabs(4).split("\n")
    char_w = mono("M" * 10, size=size).width / 10
    line_h = mono("Mg", size=size).height * 1.6
    lines = VGroup()
    for k, ln in enumerate(src_lines):
        y = -k * line_h
        if ln.strip():
            t = mono(ln.strip(), size=size)
            _paint_line(t, ln.strip())
            indent = len(ln) - len(ln.lstrip(" "))
            t.move_to([indent * char_w + t.width / 2, y, 0])
        else:
            t = Dot([0, y, 0], radius=0.01).set_opacity(0)
        lines.add(t)
    widest = max([len(l) for l in src_lines] + [8]) * char_w
    pad = 0.35
    card_h = (len(src_lines) - 1) * line_h + line_h * 0.8 + 2 * pad
    card = RoundedRectangle(width=widest + 2 * pad, height=card_h, corner_radius=0.16)
    card.set_fill(BG2, 1).set_stroke(LINE, 1.5)
    card.move_to([widest / 2, -(len(src_lines) - 1) * line_h / 2, 0])
    group = CodeBlock(card, lines)
    group.card, group.lines = card, lines
    group._row_ratio = line_h / card_h
    # Layering: card, then highlight_line bars, then text, regardless of the order they are added.
    card.set_z_index(0)
    lines.set_z_index(2)
    group.move_to(ORIGIN)
    fit(group, SAFE_W, SAFE_H - 0.8)
    return group


def highlight_line(code: CodeBlock, i: int, color: str = EMBER) -> Rectangle:
    """Translucent bar behind line i of a code_block (add it before the code so it sits behind)."""
    row_h = code.card.height * getattr(code, "_row_ratio", 0.1)
    bar = Rectangle(width=code.card.width - 0.1, height=row_h)
    bar.set_fill(color, 0.22).set_stroke(width=0)
    bar.set_z_index(1)
    bar.move_to([code.card.get_center()[0], code.lines[i].get_center()[1], 0])
    return bar


# =============================================================================================
# Math objects


def _fmt(v: float) -> str:
    v = float(v)
    s = str(int(round(v))) if abs(v - round(v)) < 1e-9 else f"{v:.2f}".rstrip("0").rstrip(".")
    return s.replace("-", "−")


def _compact(v: float) -> str:
    a = abs(v)
    for div, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if a >= div * 10 or (a >= div and abs(a / div - round(a / div)) < 1e-9):
            return _fmt(v / div) + suffix
    return _fmt(v)


def grid(x_range=(-7, 7, 1), y_range=(-4, 4, 1), unit: float = 1.0, faded: bool = False) -> NumberPlane:
    """NumberPlane in house colours. Works with ApplyMatrix; plane.c2p(x, y) for points."""
    xr, yr = list(x_range), list(y_range)
    plane = NumberPlane(
        x_range=xr, y_range=yr,
        x_length=(xr[1] - xr[0]) * unit, y_length=(yr[1] - yr[0]) * unit,
        background_line_style={"stroke_color": LINE, "stroke_width": 1.5,
                               "stroke_opacity": 0.5 if faded else 1.0},
        axis_config={"stroke_color": MUTED, "stroke_width": 2.5, "include_ticks": False},
        faded_line_ratio=1,
    )
    if faded:
        plane.axes.set_stroke(opacity=0.5)
    return plane


def vector(end, color: str = EMBER, start=(0, 0), plane=None, stroke: float = 6) -> Arrow:
    """Arrow from start to end. With `plane`, coordinates are in plane units."""
    def p(v):
        v = list(v) + [0, 0]
        return plane.c2p(v[0], v[1]) if plane is not None else np.array([v[0], v[1], 0.0])
    return Arrow(p(start), p(end), buff=0, color=color, stroke_width=stroke,
                 max_tip_length_to_length_ratio=0.25, tip_length=0.25)


class Chart(VGroup):
    """Axes with Text tick labels. `.ax` is the Manim Axes; c2p / plot are forwarded to it."""

    def c2p(self, *a, **k):
        return self.ax.c2p(*a, **k)

    def coords_to_point(self, *a, **k):
        return self.ax.c2p(*a, **k)

    def p2c(self, *a, **k):
        return self.ax.p2c(*a, **k)

    def plot(self, *a, **k):
        return self.ax.plot(*a, **k)

    def input_to_graph_point(self, *a, **k):
        return self.ax.input_to_graph_point(*a, **k)


def _ticks(lo: float, hi: float, step: float) -> list[float]:
    vals, v = [], lo
    while v <= hi + 1e-9 and len(vals) < 60:
        vals.append(round(v, 6))
        v += step
    return vals


def _range3(r) -> list[float]:
    r = list(r)[:3]
    return r + [1] * (3 - len(r))


def axes(x_range=(-1, 6, 1), y_range=(-1, 4, 1), width: float = 8, height: float = 5,
         x_label: str | None = None, y_label: str | None = None, numbers: bool = True,
         size: float = 20) -> Chart:
    """Axes with mono tick numbers and optional axis labels. Use `.ax` (or the chart itself) for c2p/plot."""
    xr, yr = _range3(x_range), _range3(y_range)
    ax = Axes(x_range=xr, y_range=yr, x_length=width, y_length=height, tips=False,
              axis_config={"stroke_color": MUTED, "stroke_width": 2.5, "include_numbers": False,
                           "tick_size": 0.06})
    chart = Chart(ax)
    chart.ax = ax
    nums = VGroup()
    if numbers:
        x0 = 0 if xr[0] <= 0 <= xr[1] else xr[0]
        y0 = 0 if yr[0] <= 0 <= yr[1] else yr[0]
        for v in _ticks(xr[0], xr[1], xr[2]):
            if abs(v - x0) < 1e-9 and yr[0] < 0 < yr[1]:
                continue
            nums.add(mono(_fmt(v), size=size, color=MUTED).next_to(ax.c2p(v, y0), DOWN, buff=0.15))
        for v in _ticks(yr[0], yr[1], yr[2]):
            if abs(v - y0) < 1e-9:
                continue
            nums.add(mono(_fmt(v), size=size, color=MUTED).next_to(ax.c2p(x0, v), LEFT, buff=0.15))
    chart.numbers = nums
    chart.add(nums)
    chart.x_label = chart.y_label = None
    if x_label:
        chart.x_label = body(x_label, size=26, color=MUTED)
        chart.x_label.next_to(ax.x_axis.get_end(), DOWN, buff=0.45).align_to(ax.x_axis.get_end(), RIGHT)
        chart.add(chart.x_label)
    if y_label:
        chart.y_label = body(y_label, size=26, color=MUTED).next_to(ax.y_axis.get_end(), RIGHT, buff=0.2)
        chart.add(chart.y_label)
    return chart


class NumLine(VGroup):
    """`.line` is the NumberLine, `.numbers` the Text labels. n2p(x) gives the point for x."""

    def n2p(self, x):
        return self.line.n2p(x)

    def number_to_point(self, x):
        return self.line.n2p(x)


def number_line(x_range=(-5, 5, 1), length: float = 10, numbers: bool = True, color: str = MUTED,
                size: float = 22) -> NumLine:
    xr = _range3(x_range)
    line = NumberLine(x_range=xr, length=length, color=color, stroke_width=2.5, include_numbers=False,
                      tick_size=0.08)
    g = NumLine(line)
    g.line = line
    g.numbers = VGroup()
    if numbers:
        for v in _ticks(xr[0], xr[1], xr[2]):
            g.numbers.add(mono(_fmt(v), size=size, color=MUTED).next_to(line.n2p(v), DOWN, buff=0.2))
        g.add(g.numbers)
    return g


class MatrixGroup(VGroup):
    """Bracketed matrix. `.entries[r][c]`, `.brackets`."""


def matrix(rows, color: str = INK, size: float = 36, col_buff: float = 0.6, row_buff: float = 0.35,
           bracket_color: str = MUTED) -> MatrixGroup:
    """Matrix of Text entries between square brackets."""
    cells = [[equation(_fmt(v) if isinstance(v, (int, float)) else str(v), size=size, color=color)
              for v in r] for r in rows]
    n_cols = max(len(r) for r in cells)
    col_w = [max((r[c].width for r in cells if c < len(r)), default=0.3) for c in range(n_cols)]
    row_h = max((m.height for r in cells for m in r), default=0.4)
    entries = VGroup()
    for i, r in enumerate(cells):
        rg = VGroup()
        for j, m in enumerate(r):
            m.move_to([sum(col_w[:j]) + j * col_buff + col_w[j] / 2, -i * (row_h + row_buff), 0])
            rg.add(m)
        entries.add(rg)
    entries.move_to(ORIGIN)
    half_h = entries.height / 2 + 0.18
    lip = 0.14

    def bracket(side: int) -> VMobject:
        x = entries.get_right()[0] + 0.22 if side > 0 else entries.get_left()[0] - 0.22
        pts = [[x - side * lip, half_h, 0], [x, half_h, 0], [x, -half_h, 0], [x - side * lip, -half_h, 0]]
        return VMobject().set_points_as_corners(pts).set_stroke(bracket_color, 3)

    brackets = VGroup(bracket(-1), bracket(1))
    g = MatrixGroup(entries, brackets)
    g.entries, g.brackets = entries, brackets
    return g


class BarChart(VGroup):
    """`.bars`, `.labels`, `.values`, `.base`."""


def bar_compare(items, max_height: float = 4.0, bar_width: float = 1.0, gap: float = 0.6,
                colors=None, size: float = 24) -> BarChart:
    """Bars for [(label, value), ...] scaled to the largest value. Grow with GrowFromEdge(bar, DOWN)."""
    items = list(items)
    colors = colors or ACCENTS
    top = max((abs(float(v)) for _, v in items), default=1.0) or 1.0
    bars, labels, values = VGroup(), VGroup(), VGroup()
    for k, (name, v) in enumerate(items):
        x = k * (bar_width + gap)
        hgt = max(0.04, abs(float(v)) / top * max_height)
        b = Rectangle(width=bar_width, height=hgt).set_fill(colors[k % len(colors)], 0.9).set_stroke(width=0)
        b.move_to([x, hgt / 2, 0])
        bars.add(b)
        labels.add(fit(body(str(name), size=size, color=MUTED), bar_width + gap * 0.9, 0.8)
                   .next_to([x, 0, 0], DOWN, buff=0.18))
        values.add(fit(mono(_compact(float(v)), size=size, color=INK), bar_width + gap * 0.9, 0.8)
                   .next_to(b, UP, buff=0.12))
    right = (len(items) - 1) * (bar_width + gap) + bar_width / 2
    base = Line([-bar_width / 2 - 0.2, 0, 0], [right + 0.2, 0, 0]).set_stroke(LINE, 2.5)
    g = BarChart(base, bars, labels, values)
    g.bars, g.labels, g.values, g.base = bars, labels, values, base
    g.move_to(ORIGIN)
    return g


# =============================================================================================
# Timing (beat sync with the narration)

_beat_ends: list[float] = []


def _clock(scene) -> float:
    t = getattr(scene, "time", None)
    if isinstance(t, (int, float)):
        return float(t)
    return float(scene.renderer.time)


def wait_until(scene, t: float):
    """Pad with scene.wait until the scene clock reads t seconds. Never shortens anything.

    Records where each beat really ended (env STUDIO_MARKS) so the mux can place the narration."""
    now = _clock(scene)
    if t - now > 1 / 30:
        scene.wait(t - now)
    elif now > t + 0.25:
        print(f"[kit] beat ran long: {now:.2f}s vs target {t:.2f}s", file=sys.stderr)
    _beat_ends.append(_clock(scene))
    marks = os.environ.get("STUDIO_MARKS")
    if marks:
        try:
            Path(marks).write_text(json.dumps(_beat_ends))
        except OSError:
            pass


def budget(scene, t: float, fraction: float = 1.0) -> float:
    """Seconds left until t, times fraction (at least 0.3). Handy as the last run_time of a beat."""
    return max(0.3, (t - _clock(scene)) * fraction)


# =============================================================================================
# LaTeX-free stand-ins for MathTex, Tex, DecimalNumber and Integer


class MathTex(VGroup):
    """Each string argument becomes one Text part (self[i]), drawn from its Unicode form."""

    def __init__(self, *tex_strings, color=INK, font_size: float = 48, tex_to_color_map=None,
                 arg_separator: str = " ", **_ignored):
        super().__init__()
        self.tex_strings = [str(s) for s in tex_strings] or [""]
        self.tex_string = arg_separator.join(self.tex_strings)
        for s in self.tex_strings:
            part = _text(unicode_math(s).strip() or " ", SANS, font_size, color)
            part.tex_string = s
            self.add(part)
        if len(self.submobjects) > 1:
            self.arrange(RIGHT, buff=0.1)
        for k, v in (tex_to_color_map or {}).items():
            self.set_color_by_tex(k, v)

    def get_parts_by_tex(self, tex, **_):
        return VGroup(*[p for p in self.submobjects if tex in getattr(p, "tex_string", "")])

    def get_part_by_tex(self, tex, **_):
        parts = self.get_parts_by_tex(tex)
        return parts[0] if len(parts) else None

    def index_of_part_by_tex(self, tex, **_):
        p = self.get_part_by_tex(tex)
        return self.submobjects.index(p) if p is not None else -1

    def set_color_by_tex(self, tex, color, **_):
        for p in self.get_parts_by_tex(tex):
            p.set_color(color)
        return self

    def set_color_by_tex_to_color_map(self, mapping, **_):
        for k, v in mapping.items():
            self.set_color_by_tex(k, v)
        return self

    def get_tex_string(self):
        return self.tex_string


class Tex(MathTex):
    pass


class SingleStringMathTex(MathTex):
    pass


class DecimalNumber(VGroup):
    """A number drawn as Text. set_value(v) redraws it in place; works with ValueTracker updaters."""

    def __init__(self, number: float = 0, num_decimal_places: int = 2, include_sign: bool = False,
                 group_with_commas: bool = True, unit: str | None = None, font_size: float = 48,
                 color=INK, edge_to_fix=LEFT, **_ignored):
        super().__init__()
        self.num_decimal_places = num_decimal_places
        self.include_sign = include_sign
        self.group_with_commas = group_with_commas
        self.unit = unit
        self._size = font_size
        self._colour = color
        self.edge_to_fix = edge_to_fix
        self.number = number
        self._draw(None, number)

    def _string(self, v: float) -> str:
        spec = f"{'+' if self.include_sign else ''}{',' if self.group_with_commas else ''}.{self.num_decimal_places}f"
        v = float(v)
        if round(v, self.num_decimal_places) == 0:
            v = 0.0  # no "−0"
        s = format(v, spec).replace("-", "−")
        return s + (unicode_math(self.unit) if self.unit else "")

    def _draw(self, old: float | None, new: float):
        t = _text(self._string(new), SANS, self._size, self._colour)
        if self.submobjects and old is not None:
            base = _text(self._string(old), SANS, self._size, self._colour).height
            if base > 1e-6 and self.height > 1e-6:
                t.scale(self.height / base)  # keep any scaling applied since creation
            t.move_to(self.get_critical_point(self.edge_to_fix), aligned_edge=self.edge_to_fix)
        self.submobjects = list(t.submobjects)

    def set_value(self, number: float):
        old, self.number = self.number, number
        self._draw(old, number)
        return self

    def get_value(self) -> float:
        return float(self.number)

    def increment_value(self, delta: float = 1):
        return self.set_value(self.get_value() + delta)

    def set_color(self, color=None, family=True):
        if color is not None:
            self._colour = color
        return super().set_color(color, family)


class Integer(DecimalNumber):
    def __init__(self, number: float = 0, num_decimal_places: int = 0, **kwargs):
        super().__init__(number, num_decimal_places=num_decimal_places, **kwargs)

    def get_value(self) -> int:
        return int(round(self.number))


def _install_latex_free_classes():
    """Point every loaded Manim module at the stand-ins, including default arguments bound at import."""
    from manim.mobject.text import numbers as num_mod
    from manim.mobject.text import tex_mobject as tex_mod

    swap = {
        tex_mod.MathTex: MathTex,
        tex_mod.Tex: Tex,
        tex_mod.SingleStringMathTex: SingleStringMathTex,
        num_mod.DecimalNumber: DecimalNumber,
        num_mod.Integer: Integer,
    }
    seen: set[int] = set()

    def fix_defaults(fn):
        if id(fn) in seen:
            return
        seen.add(id(fn))
        d = getattr(fn, "__defaults__", None)
        if d:
            fn.__defaults__ = tuple(swap.get(x, x) if isinstance(x, type) else x for x in d)
        kd = getattr(fn, "__kwdefaults__", None)
        if kd:
            fn.__kwdefaults__ = {k: swap.get(x, x) if isinstance(x, type) else x for k, x in kd.items()}

    for name, module in list(sys.modules.items()):
        if module is None or not (name == "manim" or name.startswith("manim.")):
            continue
        for attr, value in list(vars(module).items()):
            if isinstance(value, type) and value in swap:
                setattr(module, attr, swap[value])
            elif inspect.isclass(value) and str(getattr(value, "__module__", "")).startswith("manim"):
                for member in vars(value).values():
                    if inspect.isfunction(member):
                        fix_defaults(member)
            elif inspect.isfunction(value):
                fix_defaults(value)


_install_latex_free_classes()

__all__ = [
    name for name in dir()
    if not name.startswith("_")
    and name not in {"annotations", "inspect", "json", "os", "re", "sys", "Path", "manimpango",
                     "rate_functions"}
] + ["np"]
