"""Golden images for the native screen-mark compositor, made by the Python app's own code.

Draws a few synthetic captures (a Retina window with text and rounded, see-through corners,
a big one that has to shrink to 1568 px, a 1x desktop region with no alpha), then runs
mark_capture.composite_png on each, with marks and without. The Swift tests compare
MarkCompositor's output against these: without marks the palette, alpha and filtered rows
must match exactly, and with marks the ink has to land in the same places.

Needs Pillow, so run it with the Python app's runtime, without writing bytecode:
    "$HOME/Library/Application Support/Voice Type/.venv/bin/python3" -B native/scripts/make-mark-fixtures.py
It only writes into native/Tests/VoiceTypeCoreTests/Fixtures/marks.
"""

import io
import json
import math
import pathlib
import random
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import mark_capture  # noqa: E402
from screen_marks import Stroke  # noqa: E402

OUT = ROOT / "native" / "Tests" / "VoiceTypeCoreTests" / "Fixtures" / "marks"
FONT = "/System/Library/Fonts/SFNS.ttf"
P3 = pathlib.Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
WORDS = ("the build fails when the worker restarts so check the logs before you merge this "
         "branch and then ping me in slack with the trace convex deploy preview tailscale").split()


def synthetic_capture(width, height, scale, seed, *, rounded):
    """A plain app window: title bar, sidebar, lines of text, a few buttons and a header
    gradient, so the quantizer has text edges, flat areas and smooth ramps to deal with."""
    rng = random.Random(seed)
    image = Image.new("RGBA", (width, height), (250, 250, 252, 255))
    draw = ImageDraw.Draw(image)
    s = scale
    draw.rectangle((0, 0, width, 28 * s), fill=(231, 231, 235, 255))
    for i, colour in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy, r = (14 + i * 20) * s, 14 * s, 6 * s
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=colour + (255,))
    draw.rectangle((0, 28 * s, 170 * s, height), fill=(240, 241, 245, 255))
    for x in range(170 * s, width):
        t = (x - 170 * s) / max(1, width - 170 * s)
        draw.line((x, 28 * s, x, 70 * s), fill=(int(70 + 120 * t), int(110 + 60 * t), int(220 - 40 * t), 255))
    small = ImageFont.truetype(FONT, 12 * s)
    body = ImageFont.truetype(FONT, 13 * s)
    for i in range(int((height / s - 50) // 24)):
        draw.text((14 * s, (44 + i * 24) * s), " ".join(rng.choice(WORDS) for _ in range(2)).title(),
                  font=small, fill=(60, 60, 67, 255))
    y = 86 * s
    while y < height - 40 * s:
        words = " ".join(rng.choice(WORDS) for _ in range(rng.randint(6, 12)))
        colour = (0, 102, 204, 255) if rng.random() < 0.15 else (29, 29, 31, 255)
        draw.text((190 * s, y), words.capitalize() + ".", font=body, fill=colour)
        y += 22 * s
        if rng.random() < 0.12:
            bx = rng.randint(190, max(191, width // s - 140)) * s
            draw.rounded_rectangle((bx, y, bx + 110 * s, y + 26 * s), radius=6 * s, fill=(0, 122, 255, 255))
            draw.text((bx + 55 * s, y + 13 * s), "Merge", font=body, fill=(255, 255, 255, 255), anchor="mm")
            y += 36 * s
    if rounded:
        # Antialiased corners, drawn big and shrunk, like a real window capture's.
        big = Image.new("L", (width * 4, height * 4), 0)
        ImageDraw.Draw(big).rounded_rectangle((0, 0, width * 4 - 1, height * 4 - 1), radius=10 * s * 4, fill=255)
        image.putalpha(big.resize((width, height), Image.LANCZOS))
        return image
    return image.convert("RGB")


def line(start, end, steps=12):
    return [(start[0] + (end[0] - start[0]) * i / steps, start[1] + (end[1] - start[1]) * i / steps) for i in range(steps + 1)]


def circle(cx, cy, r, steps=28):
    return [(cx + r * math.cos(2 * math.pi * i / steps), cy + r * math.sin(2 * math.pi * i / steps)) for i in range(steps + 1)]


CASES = [
    {
        # A 640x400 point window at (100, 80) on a Retina display: no shrinking.
        "name": "window-2x",
        "size": (1280, 800), "scale": 2, "rounded": True, "icc": True,
        "rect": (100, 80, 640, 400),
        "marks": [line((200, 150), (420, 260)), [(600, 300), (601, 301)], circle(330, 390, 40)],
    },
    {
        # 1100x700 points on a display left of the primary (negative x), shrunk to 1568 px.
        "name": "window-large",
        "size": (2200, 1400), "scale": 2, "rounded": True, "icc": True,
        "rect": (-1300, 40, 1100, 700),
        "marks": [line((-1100, 300), (-700, 420)), [(-500, 600)]],
    },
    {
        # A desktop region on a 1x display above the primary: opaque, no profile.
        "name": "desktop-1x",
        "size": (800, 800), "scale": 1, "rounded": False, "icc": False,
        "rect": (1728, -200, 800, 800),
        "marks": [[(1900 + 30 * math.sin(i / 3), -100 + 12 * i) for i in range(25)], [(2300, 300)]],
    },
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for i, case in enumerate(CASES):
        width, height = case["size"]
        capture = synthetic_capture(width, height, case["scale"], seed=i, rounded=case["rounded"])
        raw = io.BytesIO()
        capture.save(raw, format="PNG", **({"icc_profile": P3} if case["icc"] else {}))
        (OUT / f"{case['name']}.capture.png").write_bytes(raw.getvalue())
        strokes = [Stroke(points, 0.0, 1.0, number=n + 1) for n, points in enumerate(case["marks"])]
        inked = mark_capture.composite_png(raw.getvalue(), case["rect"], strokes)
        plain = mark_capture.composite_png(raw.getvalue(), case["rect"], [])
        (OUT / f"{case['name']}.python.png").write_bytes(inked)
        (OUT / f"{case['name']}.python-plain.png").write_bytes(plain)
        manifest.append({
            "name": case["name"],
            "rect": list(case["rect"]),
            "marks": [{"number": s.number, "kind": s.kind, "points": [list(p) for p in s.points]} for s in strokes],
            "python_bytes": len(inked),
            "python_plain_bytes": len(plain),
        })
        print(f"{case['name']}: capture {len(raw.getvalue()) // 1024} KB -> {len(inked) // 1024} KB "
              f"({', '.join(s.kind for s in strokes)})")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")


if __name__ == "__main__":
    main()
