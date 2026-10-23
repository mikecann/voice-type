"""Check draw-while-dictating capture and paste without holding the key (macOS).

Run it with the installed runtime's Python so PyObjC and Pillow are there:

    PY="$HOME/Library/Application Support/Voice Type/.venv/bin/python3"

    # Which window is under a point, and what would be captured
    "$PY" debug_mark_capture.py where 800,500

    # A synthetic stroke in Quartz global points (top-left origin). One point
    # is a click mark, two or more make a line, arrow or scribble.
    "$PY" debug_mark_capture.py capture 600,400 900,520 --number 2

    # Paste text then PNGs into whatever is frontmost after a short delay,
    # through the same path a real dictation uses.
    "$PY" debug_mark_capture.py paste --text "Look at this [1]" shot.png

Screen Recording and Accessibility are checked against whatever runs this
script (usually your terminal), not the Voice Type worker.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mark_capture  # noqa: E402
import platform_mac  # noqa: E402
from screen_marks import ScreenshotStore, Stroke, mark_anchor  # noqa: E402


def _point(text: str) -> tuple[float, float]:
    x, y = text.split(",")
    return float(x), float(y)


def _default_store_dir() -> str:
    data_dir = os.path.realpath(os.path.expanduser(os.environ.get(
        "VOICE_TYPE_DATA_DIR", "~/Library/Application Support/Voice Type",
    )))
    return os.path.join(data_dir, "screenshots")


def _stroke(points: list[str], number: int) -> Stroke:
    now = time.monotonic()
    return Stroke([_point(p) for p in points], now, now, number=number)


def _check_permission() -> bool:
    if platform_mac.screen_capture_allowed():
        print("Screen Recording: allowed")
        return True
    print(
        "Screen Recording: not allowed for this process. Asking macOS now; "
        "allow it in System Settings > Privacy & Security > Screen & System "
        "Audio Recording, then run this again.",
        file=sys.stderr,
    )
    platform_mac.request_screen_capture()
    return False


def cmd_where(args) -> int:
    stroke = _stroke(args.points, 1)
    windows = mark_capture.list_windows()
    displays = mark_capture.list_displays()
    print(f"Displays: {displays}")
    print(f"Mark kind: {stroke.kind}, anchor {mark_anchor(stroke)}")
    target = mark_capture.capture_target(stroke, windows, displays, os.getpid())
    if target is None:
        print("Nothing to capture.")
        return 1
    print(f"Would capture {target.description} rect={target.rect} args={target.args}")
    return 0


def cmd_capture(args) -> int:
    if not _check_permission():
        return 2
    stroke = _stroke(args.points, args.number)
    store = ScreenshotStore(args.out or _default_store_dir())
    started = time.perf_counter()
    result = mark_capture.capture_mark(stroke, own_pid=os.getpid())
    if result is None:
        print("Nothing to capture.", file=sys.stderr)
        return 1
    png, target = result
    path = store.save(png, stroke.number)
    elapsed = (time.perf_counter() - started) * 1000
    print(f"Mark kind: {stroke.kind}; captured {target.description} in {elapsed:.0f} ms")
    print(path)
    return 0


def cmd_paste(args) -> int:
    images = []
    for path in args.images:
        with open(path, "rb") as f:
            images.append(f.read())
    print(f"Pasting in {args.delay:.1f}s; bring the target app to the front...")
    time.sleep(args.delay)
    platform_mac.snapshot_target_app()
    ok = platform_mac.inject_text_and_images(args.text, images, log=print)
    print("Landed." if ok else "Did not land; check the clipboard.")
    return 0 if ok else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    where = sub.add_parser("where", help="show the window that a mark would capture")
    where.add_argument("points", nargs="+", help="x,y in Quartz global points")
    where.set_defaults(func=cmd_where)

    capture = sub.add_parser("capture", help="capture and annotate a synthetic mark")
    capture.add_argument("points", nargs="+", help="x,y in Quartz global points")
    capture.add_argument("--number", type=int, default=1, help="badge number")
    capture.add_argument("--out", help="folder for the PNG (default: Voice Type's screenshots)")
    capture.set_defaults(func=cmd_capture)

    paste = sub.add_parser("paste", help="paste text and PNGs into the frontmost app")
    paste.add_argument("--text", default="", help="text to paste first")
    paste.add_argument("--delay", type=float, default=3.0, help="seconds to wait first")
    paste.add_argument("images", nargs="*", help="PNG files, pasted in order")
    paste.set_defaults(func=cmd_paste)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
