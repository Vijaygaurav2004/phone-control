#!/usr/bin/env python3
"""Generate the app icon for Nothing Phone 3a.app — dark slab, white phone outline, red dot."""
from PIL import Image, ImageDraw
import os, subprocess, tempfile

S = 1024

# Smooth vertical gradient, near-black like Nothing OS, masked to a rounded square
grad = Image.new("RGB", (1, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / (S - 1)
    gd.point((0, y), fill=(int(48 - 26 * t), int(48 - 26 * t), int(52 - 27 * t)))
grad = grad.resize((S, S), Image.BILINEAR)

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)

# Phone body
pw, ph = int(S * 0.40), int(S * 0.62)
px, py = (S - pw) // 2, (S - ph) // 2
r = int(pw * 0.16)
d.rounded_rectangle([px, py, px + pw, py + ph], radius=r, outline=(245, 245, 247, 255), width=int(S * 0.030))

# Screen glow inside
inset = int(S * 0.045)
d.rounded_rectangle(
    [px + inset, py + inset, px + pw - inset, py + ph - inset],
    radius=int(r * 0.7), fill=(52, 53, 58, 255),
)

# Nothing's red accent dot (camera / signature dot)
dot = int(S * 0.052)
cx, cy = S // 2, py + int(ph * 0.30)
d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=(214, 40, 40, 255))

# Three dot-matrix bars below — nods to the Glyph interface
bw, bh, gap = int(S * 0.115), int(S * 0.021), int(S * 0.040)
by = py + int(ph * 0.60)
for i, alpha in enumerate((235, 165, 100)):
    d.rounded_rectangle(
        [cx - bw // 2, by + i * (bh + gap), cx + bw // 2, by + i * (bh + gap) + bh],
        radius=bh // 2, fill=(245, 245, 247, alpha),
    )

out_dir = os.path.dirname(os.path.abspath(__file__))
img.resize((512, 512), Image.LANCZOS).save(os.path.join(out_dir, "icon.png"))
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "icon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        img.resize((size, size), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}.png")
        img.resize((size * 2, size * 2), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out_dir, "icon.icns")], check=True)

print("icon.icns written")
