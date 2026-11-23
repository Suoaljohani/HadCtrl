"""Render the HadCtrl app icon (abstract project-owned mark) to a 1024px PNG.

Mark: three ascending rounded bars (progress) resting on a baseline with a
small mint node (a decision point) — no hospital logo, no third-party marks.
Usage: python3 -I scripts/render-app-icon.py <out.png>
"""
import sys
from PIL import Image, ImageDraw

S = 1024
INK, PRIMARY, MINT, WHITE = (22, 52, 62), (22, 124, 115), (180, 238, 211), (255, 255, 255)

img = Image.new("RGB", (S, S), INK)
px = img.load()
for y in range(S):  # vertical gradient ink -> primary
    t = y / (S - 1)
    c = tuple(round(INK[i] + (PRIMARY[i] - INK[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

d = ImageDraw.Draw(img)
bar_w, gap, base_y = 150, 70, 760
heights = [230, 360, 500]
x0 = (S - (3 * bar_w + 2 * gap)) // 2
for i, h in enumerate(heights):
    x = x0 + i * (bar_w + gap)
    fill = MINT if i == 2 else WHITE
    d.rounded_rectangle([x, base_y - h, x + bar_w, base_y], radius=48, fill=fill)
d.rounded_rectangle([x0 - 40, base_y + 50, S - x0 + 40, base_y + 86], radius=18, fill=WHITE)
cx, cy, r = x0 + 2 * (bar_w + gap) + bar_w // 2, base_y - heights[2] - 110, 52
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=MINT)
img.save(sys.argv[1], "PNG", optimize=True)
