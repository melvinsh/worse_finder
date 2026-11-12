#!/usr/bin/env python3
"""Generates the app icon: 1024 px default, dark and tinted variants.

Draws at 2048 px and downsamples for clean edges. Output goes into
worse_finder/Assets.xcassets/AppIcon.appiconset/.
"""

from PIL import Image, ImageDraw, ImageFilter

S = 2048
OUT = 1024

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size), top)
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / (size - 1)))
    return img

def folder_mask():
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([392, 636, 1000, 840], radius=86, fill=255)    # tab
    d.rounded_rectangle([392, 776, 1656, 1468], radius=136, fill=255)  # body
    return mask

def make(dark=False, tinted=False):
    if tinted:
        base = gradient(S, (46, 46, 46), (18, 18, 18))
    elif dark:
        base = gradient(S, (8, 10, 18), (16, 12, 30))
    else:
        base = gradient(S, (20, 24, 44), (46, 30, 92))

    img = base.copy()

    # ambient glow behind the folder
    glow = Image.new("RGB", (S, S), (64, 74, 150) if not tinted else (100, 100, 100))
    glow_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow_mask).ellipse([S * 0.10, S * 0.16, S * 0.90, S * 0.96], fill=150)
    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(140))
    img = Image.composite(glow, img, glow_mask)

    mask = folder_mask()

    # drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 78), (0, 0), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(72))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -26))
    img = Image.alpha_composite(img.convert("RGBA"), shadow).convert("RGB")

    # folder body: one gradient across the whole union, so no seam
    top = (150, 178, 255) if not tinted else (238, 238, 238)
    bottom = (138, 102, 255) if not tinted else (158, 158, 158)
    body = Image.new("RGB", (S, S))
    bd = ImageDraw.Draw(body)
    for y in range(S):
        t = min(1.0, max(0.0, (y - 620) / 850))
        bd.line([(0, y), (S, y)], fill=lerp(top, bottom, t))
    img.paste(body, (0, 0), mask)

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # file lines
    line = (255, 255, 255, 92) if not tinted else (30, 30, 30, 90)
    for i, y in enumerate((900, 1030, 1160)):
        w = (600, 480, 340)[i]
        d.rounded_rectangle([520, y, 520 + w, y + 48], radius=24, fill=line)

    # magnifier: handle behind the ring, then a faint lens
    ring = (255, 255, 255, 255) if not tinted else (252, 252, 252, 255)
    cx, cy, r = 1392, 1168, 252
    d.line([(cx + r * 0.68, cy + r * 0.68), (cx + r * 1.34, cy + r * 1.34)],
           fill=ring, width=98)
    d.ellipse([cx + r * 1.34 - 49, cy + r * 1.34 - 49,
               cx + r * 1.34 + 49, cy + r * 1.34 + 49], fill=ring)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 26))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=ring, width=88)

    img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
    return img.resize((OUT, OUT), Image.LANCZOS)

make().save("worse_finder/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
make(dark=True).save("worse_finder/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png")
make(tinted=True).save("worse_finder/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png")
print("ok")
