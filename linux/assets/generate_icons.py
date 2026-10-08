#!/usr/bin/env python3
"""
Regenerate all WisprWave Linux icons from icon-src.png (the untouched macOS
app icon export). Dev tool only — outputs are committed, users never run it.
Requires Pillow:  ~/.local/share/wisprwave/venv/bin/python generate_icons.py

Produces, relative to this directory:
  wisprwave-app.png / wisprwave-app-64.png   app-grid icon (trimmed + rounded)
  tray/hicolor/<size>/status/wisprwave-panel*.png   tray states

NOTE: GNOME Shell caches icons by NAME (panel and app grid alike). If the
artwork changes, rename the icons and update wisprwave_tray.py ICONS and
wisprwave.desktop Icon= — otherwise users see stale icons until re-login.
"""

import os
from PIL import Image, ImageDraw, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "icon-src.png")

TRIM_FRAC = 0.15      # margin of the original canvas to cut away per side
RADIUS_FRAC = 0.24    # corner radius as fraction of the trimmed size
BADGE_FRAC = 0.19     # state-badge dot radius as fraction of icon size
TRAY_SIZES = [22, 24, 32, 48]

img = Image.open(SRC).convert("RGBA")
w = img.size[0]
m = int(w * TRIM_FRAC)
base = img.crop((m, m, w - m, w - m))
s = base.size[0]
mask = Image.new("L", (s, s), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [0, 0, s - 1, s - 1], radius=int(s * RADIUS_FRAC), fill=255)
base.putalpha(mask)


def badged(color):
    out = base.copy()
    d = ImageDraw.Draw(out)
    r = int(s * BADGE_FRAC)
    cx = cy = s - r - int(s * 0.04)
    d.ellipse([cx - r - 6, cy - r - 6, cx + r + 6, cy + r + 6],
              fill=(255, 255, 255, 255))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)
    return out


def dimmed():
    grey = ImageOps.grayscale(base).convert("RGBA")
    grey.putalpha(base.split()[3].point(lambda a: int(a * 0.55)))
    return grey


# App-grid icon
base.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "wisprwave-app.png"))
base.resize((64, 64), Image.LANCZOS).save(os.path.join(HERE, "wisprwave-app-64.png"))

# Tray state icons
variants = {
    "wisprwave-panel": base,
    "wisprwave-panel-recording": badged((224, 27, 36, 255)),   # GNOME red
    "wisprwave-panel-busy": badged((229, 165, 10, 255)),       # amber
    "wisprwave-panel-down": dimmed(),
}
for size in TRAY_SIZES:
    d = os.path.join(HERE, "tray", "hicolor", f"{size}x{size}", "status")
    os.makedirs(d, exist_ok=True)
    for name, v in variants.items():
        v.resize((size, size), Image.LANCZOS).save(os.path.join(d, f"{name}.png"))

print("icons regenerated from", SRC)
