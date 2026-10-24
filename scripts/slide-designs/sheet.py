#!/usr/bin/env python3
"""Puts the three roles of each design side by side: sheet.py <png folder> <out.png> name[,name…]"""
import sys
import pathlib
from PIL import Image, ImageDraw

folder = pathlib.Path(sys.argv[1])
names = sys.argv[3].split(",")
w, h = 480, 270
gap = 8
sheet = Image.new("RGB", (3 * w + 4 * gap, len(names) * (h + gap) + gap), (40, 40, 44))
for row, name in enumerate(names):
    for col, role in enumerate(["titel", "kapitel", "folie"]):
        path = folder / f"{name}-{role}.png"
        if not path.exists():
            continue
        img = Image.open(path).convert("RGB").resize((w, h), Image.LANCZOS)
        sheet.paste(img, (gap + col * (w + gap), gap + row * (h + gap)))
    ImageDraw.Draw(sheet).text((gap + 6, gap + row * (h + gap) + 4), name, fill=(255, 0, 160))
sheet.save(sys.argv[2])
