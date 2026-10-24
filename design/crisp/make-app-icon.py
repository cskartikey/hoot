"""Render the "wait, what?" app icon from hoot's idle sprite.

Design (handoff section 8): a squircle-style rounded square with a vertical
gradient #FFFFFF -> #EEF1F4, hoot's first idle frame centered at ~75% of the
squircle, scaled nearest-neighbour so the pixels stay crisp.

Writes every PNG listed in the existing AppIcon.appiconset/Contents.json.

    uv run --with pillow python design/crisp/make-app-icon.py
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = Path(__file__).resolve().parents[2]
SPRITE_PATH = REPO_ROOT / "Hoot/Resources/Pets/hoot.json"
APP_ICON_SET = REPO_ROOT / "Hoot/Resources/Assets.xcassets/AppIcon.appiconset"

CANVAS_SIZE = 1024
# Apple's macOS icon grid: an 824pt body centered on the 1024 canvas, leaving
# room for the drop shadow.
SQUIRCLE_SIZE = 824
SQUIRCLE_EXPONENT = 5.0  # superellipse |x|^n + |y|^n = 1; ~5 matches the macOS shape
GRADIENT_TOP = (0xFF, 0xFF, 0xFF)
GRADIENT_BOTTOM = (0xEE, 0xF1, 0xF4)
PET_SHARE_OF_SQUIRCLE = 0.75
SUPERSAMPLE = 4  # anti-alias the squircle edge


def hex_to_rgba(hex_color: str) -> tuple[int, int, int, int]:
    digits = hex_color.lstrip("#")
    if len(digits) == 6:
        digits += "FF"
    return tuple(int(digits[index:index + 2], 16) for index in range(0, 8, 2))


def squircle_mask(side: int) -> Image.Image:
    """Superellipse alpha mask of `side` px, drawn supersampled then reduced."""
    big_side = side * SUPERSAMPLE
    radius = big_side / 2
    mask = Image.new("L", (big_side, big_side), 0)
    draw = ImageDraw.Draw(mask)
    for row in range(big_side):
        normalized_y = abs((row + 0.5 - radius) / radius)
        if normalized_y >= 1:
            continue
        normalized_x = (1 - normalized_y ** SQUIRCLE_EXPONENT) ** (1 / SQUIRCLE_EXPONENT)
        half_width = normalized_x * radius
        draw.line([(radius - half_width, row), (radius + half_width - 1, row)], fill=255)
    return mask.resize((side, side), Image.LANCZOS)


def vertical_gradient(side: int) -> Image.Image:
    gradient = Image.new("RGBA", (side, side))
    draw = ImageDraw.Draw(gradient)
    for row in range(side):
        mix = row / max(1, side - 1)
        color = tuple(round(top + (bottom - top) * mix) for top, bottom in zip(GRADIENT_TOP, GRADIENT_BOTTOM))
        draw.line([(0, row), (side, row)], fill=color + (255,))
    return gradient


def hoot_idle_frame() -> Image.Image:
    sprite = json.loads(SPRITE_PATH.read_text())
    grid_size = sprite["size"]
    palette = {character: hex_to_rgba(color) for character, color in sprite["palette"].items()}
    rows = sprite["animations"]["idle"][0]["rows"]
    frame = Image.new("RGBA", (grid_size, grid_size), (0, 0, 0, 0))
    for row_index, row_characters in enumerate(rows):
        for column_index, pixel_character in enumerate(row_characters):
            if pixel_character == "." or pixel_character not in palette:
                continue
            frame.putpixel((column_index, row_index), palette[pixel_character])
    return frame


def render_icon_1024() -> Image.Image:
    icon = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    squircle_origin = (CANVAS_SIZE - SQUIRCLE_SIZE) // 2
    mask = squircle_mask(SQUIRCLE_SIZE)

    # Soft drop shadow, like the macOS icon template (offset down, blurred).
    shadow = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    shadow_alpha = Image.new("L", (CANVAS_SIZE, CANVAS_SIZE), 0)
    shadow_alpha.paste(mask, (squircle_origin, squircle_origin + 12))
    shadow_alpha = shadow_alpha.point(lambda alpha: alpha * 0.28).filter(ImageFilter.GaussianBlur(14))
    shadow.putalpha(shadow_alpha)
    icon = Image.alpha_composite(icon, shadow)

    # Gradient body.
    body = vertical_gradient(SQUIRCLE_SIZE)
    body.putalpha(mask)
    icon.alpha_composite(body, (squircle_origin, squircle_origin))

    # Hairline edge (fg @ 0.12, like the mock's inset 0.5px border) so the
    # light body still reads on a white Dock or Finder background.
    inner_mask = squircle_mask(SQUIRCLE_SIZE - 4)
    edge_alpha = mask.copy()
    edge_alpha.paste(0, (2, 2), inner_mask)
    edge_alpha = edge_alpha.point(lambda alpha: alpha * 0.12)
    edge = Image.new("RGBA", (SQUIRCLE_SIZE, SQUIRCLE_SIZE), (0, 0, 0, 255))
    edge.putalpha(edge_alpha)
    icon.alpha_composite(edge, (squircle_origin, squircle_origin))

    # Hoot, nearest-neighbour at a whole-number scale so every sprite pixel
    # is the same size.
    frame = hoot_idle_frame()
    pixels_per_sprite_pixel = round(SQUIRCLE_SIZE * PET_SHARE_OF_SQUIRCLE / frame.width)
    pet_side = frame.width * pixels_per_sprite_pixel
    pet = frame.resize((pet_side, pet_side), Image.NEAREST)
    pet_origin = (CANVAS_SIZE - pet_side) // 2
    icon.alpha_composite(pet, (pet_origin, pet_origin))
    return icon


def main() -> None:
    contents = json.loads((APP_ICON_SET / "Contents.json").read_text())
    icon_1024 = render_icon_1024()

    pixel_size_by_filename: dict[str, int] = {}
    for image_entry in contents["images"]:
        filename = image_entry.get("filename")
        if not filename:
            continue
        point_size = float(image_entry["size"].split("x")[0])
        scale = int(image_entry["scale"].rstrip("x"))
        pixel_size_by_filename[filename] = int(point_size * scale)

    for filename, pixel_size in sorted(pixel_size_by_filename.items(), key=lambda item: item[1]):
        if pixel_size == CANVAS_SIZE:
            output = icon_1024
        else:
            output = icon_1024.resize((pixel_size, pixel_size), Image.LANCZOS)
        output.save(APP_ICON_SET / filename)
        print(f"wrote {filename} ({pixel_size}px)")


if __name__ == "__main__":
    main()
