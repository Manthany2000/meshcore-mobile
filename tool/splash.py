#!/usr/bin/env python3
"""Draws the native launch-screen images: the empty radar scope from
lib/src/ui/logo.dart (RadarPainter, without the sweep or contacts), so the
in-app splash starts exactly where the native one leaves off.

    python3 tool/splash.py && dart run flutter_native_splash:create
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / 'assets' / 'splash'
PHOSPHOR = (0x9B, 0xD4, 0x5A)
FACE = (0x0E, 0x12, 0x0A, 255)
SS = 4  # supersampling, for smooth edges


def scope(px):
    """The scope, px wide, on a transparent square."""
    n = px * SS
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    s, c, r = n, n / 2, n / 2

    def circle(rad, width, a):
        d.ellipse([c - rad, c - rad, c + rad, c + rad], outline=PHOSPHOR + (a,), width=max(1, round(width)))

    d.ellipse([c - r * .98, c - r * .98, c + r * .98, c + r * .98], fill=FACE)
    # Strokes are centred on the path in Flutter: grow the outline outwards by half.
    circle(r * .98 + s * .007, s * .014, 115)
    for f in (.33, .66):
        circle(r * f + s * .003, s * .006, 115)
    w = max(1, round(s * .006))
    d.line([c - r * .98, c, c + r * .98, c], fill=PHOSPHOR + (115,), width=w)
    d.line([c, c - r * .98, c, c + r * .98], fill=PHOSPHOR + (115,), width=w)
    for deg in range(0, 360, 10):
        a = math.radians(deg)
        dx, dy = math.sin(a), -math.cos(a)
        ln = .08 if deg % 30 == 0 else .04
        d.line([c + dx * r * .98, c + dy * r * .98, c + dx * r * (.98 - ln), c + dy * r * (.98 - ln)],
               fill=PHOSPHOR + (153,), width=max(1, round(s * .007)))
    return im.resize((px, px), Image.LANCZOS)


def main():
    # iOS and older Android: the image is drawn at a quarter of its pixel size,
    # so 800 px is the in-app scope's 200 points.
    scope(800).save(OUT / 'logo.png')
    # Android 12+: a 960 px icon whose middle 640 px shows; the scope fills it.
    im = Image.new('RGBA', (960, 960), (0, 0, 0, 0))
    im.alpha_composite(scope(620), (170, 170))
    im.save(OUT / 'logo_android12.png')


if __name__ == '__main__':
    main()
