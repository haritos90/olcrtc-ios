#!/usr/bin/env python3
"""
Regenerate the app icon: takes the pixel hand (hand.png) and overlays the
"olcrtc-ios" wordmark along the diagonal, then writes the 1024x1024 icon to
the asset catalog.

Usage:
    pip install Pillow          # one-time
    python3 scripts/icon/make-icon.py

To change the icon:
  - swap a new 1024x1024 hand into scripts/icon/hand.png (orange on black), or
  - just replace App/Assets.xcassets/AppIcon.appiconset/AppIcon.png directly, or
  - tweak the TEXT / placement knobs below and re-run.
"""
from PIL import Image, ImageDraw, ImageFont
from collections import Counter
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "hand.png")
OUT  = os.path.join(HERE, "..", "..", "App", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

# ---- knobs ----
TEXT  = "olcrtc-ios"
FONT  = "/System/Library/Fonts/Monaco.ttf"   # any monospace TTF
FSIZE = 117         # text size
CX, CY = 380, 330   # text centre (px, in the 1024 canvas)
ANGLE = 45          # degrees, along the thumb<->pinky diagonal
# ---------------

hand = Image.open(SRC).convert("RGBA")
W, H = hand.size
base = Image.new("RGB", (W, H), (0, 0, 0))     # opaque black bg (iOS icons need no alpha)
base.paste(hand, (0, 0), hand)

# match the text colour to the hand's orange
cnt = Counter(base.resize((80, 80)).getdata())
orange = (196, 87, 24)
for col, _ in cnt.most_common(16):
    r, g, b = col
    if r > 90 and r > b + 20 and g < r:
        orange = col
        break

SUP = 3   # supersample the TEXT only — the hand pixels are never resampled
font = ImageFont.truetype(FONT, FSIZE * SUP)
bb = font.getbbox(TEXT)
layer = Image.new("RGBA", (bb[2]-bb[0] + 20*SUP, bb[3]-bb[1] + 20*SUP), (0, 0, 0, 0))
ImageDraw.Draw(layer).text((10*SUP - bb[0], 10*SUP - bb[1]), TEXT, font=font, fill=orange + (255,))
layer = layer.rotate(ANGLE, expand=True, resample=Image.BICUBIC)
layer = layer.resize((layer.width // SUP, layer.height // SUP), Image.LANCZOS)
base.paste(layer, (int(CX - layer.width/2), int(CY - layer.height/2)), layer)

base.save(OUT)
print("wrote", os.path.normpath(OUT), "  text colour", orange)
