"""Generate Folia HarmonyOS app icons (PNG) for AppScope and the entry module.

Draws a stylised waveform / petal mark on the app's dark background so the icon
matches the in-app theme without shipping any third-party artwork.
"""
from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFilter

OUT_DIRS = [
    r"D:\Personal\Documents\deepseek-harness\default-workspace\folia-harmonyos\AppScope\resources\base\media",
    r"D:\Personal\Documents\deepseek-harness\default-workspace\folia-harmonyos\entry\src\main\resources\base\media",
]

SIZE = 512
BG_TOP = (16, 19, 28)
BG_BOTTOM = (30, 38, 58)
ACCENT = (125, 184, 255)
ACCENT_SOFT = (168, 210, 255)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        img.putpixel(
            (0, y),
            (
                int(top[0] + (bottom[0] - top[0]) * t),
                int(top[1] + (bottom[1] - top[1]) * t),
                int(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return img.resize((size, size), Image.BILINEAR)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw_mark(size: int) -> Image.Image:
    """Five-bar waveform with a soft glow, echoing the lyric visualiser."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    bars = 5
    bar_w = size * 0.072
    gap = size * 0.045
    total_w = bars * bar_w + (bars - 1) * gap
    start_x = (size - total_w) / 2
    centre_y = size / 2

    # relative heights, smooth bell curve
    weights = [0.36, 0.68, 1.0, 0.72, 0.44]

    for i in range(bars):
        h = size * 0.46 * weights[i]
        x0 = start_x + i * (bar_w + gap)
        y0 = centre_y - h / 2
        x1 = x0 + bar_w
        y1 = centre_y + h / 2
        colour = ACCENT if i % 2 == 0 else ACCENT_SOFT
        draw.rounded_rectangle((x0, y0, x1, y1), radius=bar_w / 2, fill=colour + (255,))

    return layer


def build_icon(size: int = SIZE, radius_ratio: float = 0.22, transparent_corners: bool = True) -> Image.Image:
    bg = vertical_gradient(size, BG_TOP, BG_BOTTOM).convert("RGBA")

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        (size * 0.12, size * 0.16, size * 0.88, size * 0.92),
        fill=(125, 184, 255, 46),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.07))
    bg = Image.alpha_composite(bg, glow)

    bg = Image.alpha_composite(bg, draw_mark(size))

    if transparent_corners:
        bg.putalpha(rounded_mask(size, int(size * radius_ratio)))
    return bg


def main() -> None:
    for out_dir in OUT_DIRS:
        os.makedirs(out_dir, exist_ok=True)

    icon = build_icon()

    # AppScope icon + module icon (same artwork)
    icon.save(os.path.join(OUT_DIRS[0], "app_icon.png"))
    icon.save(os.path.join(OUT_DIRS[1], "app_icon.png"))
    # Start-window icon: square, no rounded corners so the splash does not double-round it
    build_icon(transparent_corners=False).save(os.path.join(OUT_DIRS[1], "startIcon.png")
                                               if False else os.path.join(OUT_DIRS[1], "startIcon.png"))

    for out_dir in OUT_DIRS:
        for name in sorted(os.listdir(out_dir)):
            if name.endswith(".png") and name in ("app_icon.png", "startIcon.png"):
                path = os.path.join(out_dir, name)
                print(f"{path}  {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
