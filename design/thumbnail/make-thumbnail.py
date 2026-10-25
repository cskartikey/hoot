#!/usr/bin/env python3
# Devpost thumbnail for hoot (PNG + looping GIF, 1500×1000, dark theme).
# Usage: python3 design/thumbnail/make-thumbnail.py   (needs Pillow + ffmpeg on PATH)
# Writes design/thumbnail/out/hoot-thumbnail.png and hoot-thumbnail.gif.
#
# Everything is drawn with Pillow from the real hoot sprite
# (Hoot/Resources/Pets/hoot.json) and JetBrains Mono (Hoot/Resources/Fonts).
# Pixel art is scaled with nearest-neighbour; no gradients, no shadows.

import json
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FONTS = os.path.join(REPO, "Hoot", "Resources", "Fonts")
SPRITE_PATH = os.path.join(REPO, "Hoot", "Resources", "Pets", "hoot.json")
OUT_DIR = os.path.join(HERE, "out")

WIDTH, HEIGHT = 1500, 1000
FPS = 12
LOOP_SECONDS = 4.0

# --- theme (WaitWhatTheme, dark) ------------------------------------------
BG = (0x16, 0x16, 0x17)
INK = (0xF2, 0xF2, 0xF7)
MUTED = (0x98, 0x98, 0x9D)
EMBER = (0xE5, 0x67, 0x3A)
BLUE = (0x3F, 0x7F, 0xE0)
GRID = (0x1C, 0x1C, 0x1E)          # faint pixel grid over BG
BUBBLE_FILL = (0x28, 0x28, 0x2B)    # the app's glass tint, flattened onto BG
BUBBLE_STROKE = (0x30, 0x30, 0x33)  # ink at 12% over BG


def blend(color, alpha, over=BG):
    return tuple(round(over[i] * (1 - alpha) + color[i] * alpha) for i in range(3))


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, f"JetBrainsMono-{weight}.ttf"), size)


# --- sprite ---------------------------------------------------------------
with open(SPRITE_PATH) as handle:
    SPRITE = json.load(handle)


def hex_to_rgba(value):
    value = value.lstrip("#")
    r, g, b = int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)
    a = int(value[6:8], 16) if len(value) == 8 else 255
    return (r, g, b, a)


PALETTE = {key: hex_to_rgba(value) for key, value in SPRITE["palette"].items()}


def sprite_frame(animation, index, scale):
    """One animation frame as an RGBA image, scaled with nearest-neighbour."""
    frames = SPRITE["animations"][animation]
    rows = frames[index % len(frames)]["rows"]
    size = SPRITE["size"]
    tiny = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = tiny.load()
    for y, row in enumerate(rows):
        for x, key in enumerate(row):
            if key != ".":
                pixels[x, y] = PALETTE[key]
    return tiny.resize((size * scale, size * scale), Image.NEAREST)


# --- layout ---------------------------------------------------------------
OWL_SCALE = 17
OWL_X, OWL_Y = 78, 388                     # owl's 24×24 cell, top-left
OWL_SIZE = SPRITE["size"] * OWL_SCALE      # 408

BUBBLE_TEXT = "wait, what?"
BUBBLE_FONT = font("SemiBold", 54)
BUBBLE_PAD_X, BUBBLE_PAD_Y = 34, 22
BUBBLE_X, BUBBLE_Y = 214, 218              # top-left of the bubble box
BUBBLE_RADIUS = 14

COLUMN_X = 578
WORDMARK_FONT = font("SemiBold", 212)
WORDMARK_Y = 300
TAGLINE_FONT = font("Regular", 31)
TAGLINE = "the friend who sits next to you in lecture."
TAGLINE_Y = 556

NOTES_FONT = font("Regular", 29)
NOTES_PREFIX = "the eigenvalues of a "
NOTES_WORD = "symmetric"
NOTES_SUFFIX = " matrix are real"
NOTES_Y = 704
TAB_FONT = font("Medium", 19)
TAB_LABEL = "this one"

CURSOR_GAP = 18


def text_width(text, fnt):
    return fnt.getlength(text)


def draw_background(image):
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, WIDTH, HEIGHT], fill=BG)
    step = 50
    for x in range(0, WIDTH, step):
        draw.line([(x, 0), (x, HEIGHT)], fill=GRID, width=1)
    for y in range(0, HEIGHT, step):
        draw.line([(0, y), (WIDTH, y)], fill=GRID, width=1)


def draw_bubble(image, visible_chars):
    """The app's answer bubble: flat glass fill, hairline stroke, pixel tail."""
    if visible_chars <= 0:
        return
    draw = ImageDraw.Draw(image)
    ascent, descent = BUBBLE_FONT.getmetrics()
    full_width = text_width(BUBBLE_TEXT, BUBBLE_FONT)
    box_w = full_width + BUBBLE_PAD_X * 2
    box_h = ascent + descent + BUBBLE_PAD_Y * 2
    x0, y0 = BUBBLE_X, BUBBLE_Y
    x1, y1 = x0 + box_w, y0 + box_h
    draw.rounded_rectangle([x0, y0, x1, y1], radius=BUBBLE_RADIUS, fill=BUBBLE_FILL, outline=BUBBLE_STROKE, width=2)
    # Stepped pixel tail toward the owl's head: three shrinking steps that
    # share a straight left edge, outlined like the bubble, open at the top.
    tail_x = x0 + 56
    steps = [(30, 12), (20, 12), (10, 12)]
    y = y1 - 2
    for step_w, step_h in steps:
        draw.rectangle([tail_x, y, tail_x + step_w, y + step_h], fill=BUBBLE_FILL, outline=BUBBLE_STROKE, width=2)
        y += step_h - 2
    y = y1 - 2
    for step_w, step_h in steps:
        draw.rectangle([tail_x + 2, y - 2, tail_x + step_w - 2, y + step_h - 2], fill=BUBBLE_FILL)
        y += step_h - 2
    draw.rectangle([tail_x, y1 - 4, tail_x + 1, y1 + 2], fill=BUBBLE_STROKE)
    draw.text((x0 + BUBBLE_PAD_X, y0 + BUBBLE_PAD_Y), BUBBLE_TEXT[:visible_chars], font=BUBBLE_FONT, fill=INK)


def draw_wordmark(image, cursor_on):
    draw = ImageDraw.Draw(image)
    x = COLUMN_X
    draw.text((x, WORDMARK_Y), "hoot", font=WORDMARK_FONT, fill=INK)
    x += text_width("hoot", WORDMARK_FONT)
    draw.text((x, WORDMARK_Y), ".", font=WORDMARK_FONT, fill=EMBER)
    x += text_width(".", WORDMARK_FONT)
    if cursor_on:
        # Block cursor the height of the x-height band, like a terminal caret.
        bbox = WORDMARK_FONT.getbbox("o")
        top = WORDMARK_Y + bbox[1]
        bottom = WORDMARK_Y + bbox[3]
        cursor_w = int(text_width("o", WORDMARK_FONT) * 0.62)
        draw.rectangle([x + CURSOR_GAP, top, x + CURSOR_GAP + cursor_w, bottom], fill=EMBER)


def draw_tagline(image):
    ImageDraw.Draw(image).text((COLUMN_X, TAGLINE_Y), TAGLINE, font=TAGLINE_FONT, fill=MUTED)


def draw_notes(image, frame_progress):
    """A line of lecture notes with hoot's index-card frame around one word.

    frame_progress: 0 = no frame, 0..1 = edges drawing clockwise from the
    top-left, 1 = full frame with the tab.
    """
    draw = ImageDraw.Draw(image)
    x = COLUMN_X
    draw.text((x, NOTES_Y), NOTES_PREFIX, font=NOTES_FONT, fill=MUTED)
    x += text_width(NOTES_PREFIX, NOTES_FONT)
    word_x = x
    word_w = text_width(NOTES_WORD, NOTES_FONT)

    # Frame box: the word plus padding (PetPointingFrame: 4pt each side → 2×).
    ascent, descent = NOTES_FONT.getmetrics()
    pad = 10
    fx0 = int(word_x - pad)
    fy0 = int(NOTES_Y - pad + 4)
    fx1 = int(word_x + word_w + pad)
    fy1 = int(NOTES_Y + ascent + descent + pad - 4)
    edge = 3
    notch = 3
    depth = 6

    if frame_progress >= 1:
        # Faint fill and the offset "card depth" edge (bottom + right), under the word.
        draw.rectangle([fx0, fy0, fx1, fy1], fill=blend(EMBER, 0.14))
        draw.rectangle([fx0 + depth, fy1 + depth - edge, fx1 + depth, fy1 + depth], fill=blend(EMBER, 0.45))
        draw.rectangle([fx1 + depth - edge, fy0 + depth, fx1 + depth, fy1 + depth], fill=blend(EMBER, 0.45))
    draw.text((x, NOTES_Y), NOTES_WORD, font=NOTES_FONT, fill=INK)
    x += word_w
    draw.text((x, NOTES_Y), NOTES_SUFFIX, font=NOTES_FONT, fill=MUTED)
    if frame_progress <= 0:
        return

    perimeter = 2 * (fx1 - fx0) + 2 * (fy1 - fy0)
    drawn = frame_progress * perimeter

    # Edges, clockwise, as far as `drawn` reaches.
    def segment(a, b, remaining, horizontal):
        length = abs(b[0] - a[0]) if horizontal else abs(b[1] - a[1])
        take = max(0, min(length, remaining))
        if take <= 0:
            return 0
        if horizontal:
            direction = 1 if b[0] > a[0] else -1
            x_end = a[0] + direction * take
            draw.rectangle([min(a[0], x_end), a[1], max(a[0], x_end), a[1] + edge - 1], fill=EMBER)
        else:
            direction = 1 if b[1] > a[1] else -1
            y_end = a[1] + direction * take
            draw.rectangle([a[0], min(a[1], y_end), a[0] + edge - 1, max(a[1], y_end)], fill=EMBER)
        return take

    remaining = drawn
    remaining -= segment((fx0, fy0), (fx1, fy0), remaining, True)
    remaining -= segment((fx1 - edge + 1, fy0), (fx1 - edge + 1, fy1), remaining, False)
    remaining -= segment((fx1, fy1 - edge + 1), (fx0, fy1 - edge + 1), remaining, True)
    remaining -= segment((fx0, fy1), (fx0, fy0), remaining, False)

    if frame_progress >= 1:
        # 1-pixel notched corners (scaled to the frame's edge size).
        for cx, cy in ((fx0, fy0), (fx1 - notch + 1, fy0), (fx0, fy1 - notch + 1), (fx1 - notch + 1, fy1 - notch + 1)):
            draw.rectangle([cx, cy, cx + notch - 1, cy + notch - 1], fill=BG)
        # Tab growing out of the top edge, inset from the frame's left.
        tab_h = 30
        tab_pad = 12
        tab_w = int(text_width(TAB_LABEL, TAB_FONT)) + tab_pad * 2
        tx0 = fx0 + 14
        ty0 = fy0 - tab_h + edge
        draw.rectangle([tx0, ty0, tx0 + tab_w, fy0 + edge - 1], fill=EMBER)
        t_ascent, t_descent = TAB_FONT.getmetrics()
        draw.text((tx0 + tab_pad, ty0 + (tab_h - t_ascent - t_descent) // 2 + 1), TAB_LABEL, font=TAB_FONT, fill=BG)


def draw_owl(image, animation, index):
    frame = sprite_frame(animation, index, OWL_SCALE)
    image.alpha_composite(frame, (OWL_X, OWL_Y))


def render(owl_animation="idle", owl_index=0, bubble_chars=None, cursor_on=True, frame_progress=1.0):
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    draw_background(image)
    draw_owl(image, owl_animation, owl_index)
    draw_bubble(image, len(BUBBLE_TEXT) if bubble_chars is None else bubble_chars)
    draw_wordmark(image, cursor_on)
    draw_tagline(image)
    draw_notes(image, frame_progress)
    return image.convert("RGB")


# --- GIF timeline ----------------------------------------------------------
def owl_pose_at(t):
    """hoot listens while the question types in, talks while it points, then idles."""
    if t < 0.25:
        return "idle", 0
    if t < 1.55:
        return "listening", int((t - 0.25) / 0.24)
    if t < 3.1:
        return "talking", int((t - 1.55) / 0.16)
    # Idle: bob every half second, one quick blink (the 130ms frame) at 3.4s.
    if 3.4 <= t < 3.55:
        return "idle", 4
    return "idle", int(t * 2) % 2


def gif_frame_params(t):
    typed = 0 if t < 0.3 else min(len(BUBBLE_TEXT), int((t - 0.3) / 0.075) + 1)
    if t >= 3.75:
        typed = 0
    if t < 1.75:
        progress = 0.0
    elif t < 2.35:
        progress = (t - 1.75) / 0.6
    elif t < 3.75:
        progress = 1.0
    else:
        progress = 0.0
    cursor_on = int(t * 2) % 2 == 0
    animation, index = owl_pose_at(t)
    return dict(owl_animation=animation, owl_index=index, bubble_chars=typed, cursor_on=cursor_on, frame_progress=progress)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    png_path = os.path.join(OUT_DIR, "hoot-thumbnail.png")
    gif_path = os.path.join(OUT_DIR, "hoot-thumbnail.gif")

    render().save(png_path, optimize=True)
    print("wrote", png_path, os.path.getsize(png_path) // 1024, "KB")

    frame_dir = tempfile.mkdtemp(prefix="hoot-thumb-")
    try:
        total = int(LOOP_SECONDS * FPS)
        for i in range(total):
            t = i / FPS
            render(**gif_frame_params(t)).save(os.path.join(frame_dir, f"f{i:03d}.png"))
        pattern = os.path.join(frame_dir, "f%03d.png")
        filters = (
            f"[0:v]fps={FPS},split[a][b];"
            "[a]palettegen=max_colors=256:stats_mode=full[p];"
            "[b][p]paletteuse=dither=none"
        )
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", pattern,
             "-filter_complex", filters, "-loop", "0", gif_path],
            check=True,
        )
        print("wrote", gif_path, os.path.getsize(gif_path) // 1024, "KB")
    finally:
        shutil.rmtree(frame_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
