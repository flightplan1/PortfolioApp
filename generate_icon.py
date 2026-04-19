#!/usr/bin/env python3
"""Generate PortfolioApp icons: light, dark, and tinted variants."""

import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
ICON_DIR = "PortfolioApp/PortfolioApp/PortfolioApp/Assets.xcassets/AppIcon.appiconset"

def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask

def draw_chart(draw, size, line_color, line_width=18, glow_color=None):
    """Draw an upward-trending line chart."""
    pad = int(size * 0.15)
    chart_w = size - pad * 2
    chart_h = int(size * 0.52)
    base_y = int(size * 0.72)

    # Control points for a smooth upward curve (left=low, right=high)
    points_norm = [
        (0.00, 0.08),
        (0.12, 0.15),
        (0.25, 0.25),
        (0.38, 0.20),
        (0.50, 0.40),
        (0.62, 0.55),
        (0.75, 0.68),
        (0.88, 0.78),
        (1.00, 0.90),
    ]

    pts = [(pad + x * chart_w, base_y - y * chart_h) for x, y in points_norm]

    # Glow pass
    if glow_color:
        for offset in range(8, 0, -2):
            draw.line(pts, fill=glow_color, width=line_width + offset * 3, joint="curve")

    # Main line
    draw.line(pts, fill=line_color, width=line_width, joint="curve")

    # Endpoint dot
    ex, ey = pts[-1]
    r = line_width * 1.4
    draw.ellipse([ex - r, ey - r, ex + r, ey + r], fill=line_color)

    return pts

def draw_grid(draw, size):
    """Subtle horizontal grid lines."""
    pad = int(size * 0.15)
    chart_h = int(size * 0.52)
    base_y = int(size * 0.72)
    for i in range(1, 4):
        y = base_y - (i / 3) * chart_h
        draw.line([(pad, y), (size - pad, y)], fill=(255, 255, 255, 18), width=2)

def make_light_icon():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = ImageDraw.Draw(img)

    # Deep navy-to-indigo gradient background
    for y in range(SIZE):
        t = y / SIZE
        r = int(12 + t * 8)
        g = int(18 + t * 12)
        b = int(52 + t * 28)
        bg.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    d = ImageDraw.Draw(img)
    draw_grid(d, SIZE)

    # Emerald-green chart with soft glow
    draw_chart(d, SIZE,
               line_color=(52, 211, 153),
               line_width=22,
               glow_color=(52, 211, 153, 30))

    # Apply iOS rounded corners
    mask = rounded_rect_mask(SIZE, int(SIZE * 0.2237))
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result

def make_dark_icon():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = ImageDraw.Draw(img)

    # Almost black background with slight warm tint
    for y in range(SIZE):
        t = y / SIZE
        r = int(10 + t * 6)
        g = int(10 + t * 8)
        b = int(14 + t * 10)
        bg.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    d = ImageDraw.Draw(img)
    draw_grid(d, SIZE)

    # Bright cyan-green chart
    draw_chart(d, SIZE,
               line_color=(110, 231, 183),
               line_width=22,
               glow_color=(110, 231, 183, 25))

    mask = rounded_rect_mask(SIZE, int(SIZE * 0.2237))
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result

def make_tinted_icon():
    """Tinted variant: monochrome white on white — iOS will colorize it."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = ImageDraw.Draw(img)

    # Medium gray background
    bg.rectangle([0, 0, SIZE, SIZE], fill=(100, 100, 100, 255))

    d = ImageDraw.Draw(img)

    # White chart line
    draw_chart(d, SIZE, line_color=(255, 255, 255), line_width=22)

    mask = rounded_rect_mask(SIZE, int(SIZE * 0.2237))
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result

if __name__ == "__main__":
    import os
    os.makedirs(ICON_DIR, exist_ok=True)

    light = make_light_icon()
    light.save(f"{ICON_DIR}/AppIcon-Light.png")
    print("Saved AppIcon-Light.png")

    dark = make_dark_icon()
    dark.save(f"{ICON_DIR}/AppIcon-Dark.png")
    print("Saved AppIcon-Dark.png")

    tinted = make_tinted_icon()
    tinted.save(f"{ICON_DIR}/AppIcon-Tinted.png")
    print("Saved AppIcon-Tinted.png")

    print("Done.")
