"""Turn screen marks into annotated screenshots (macOS).

Each finished mark is queued from the event tap thread and captured here on
a worker thread, while the key is still held, so the screenshot shows what
Mike was pointing at when he drew. The window under the mark is captured on
its own with `screencapture -l`, which is Apple's supported tool and still
works on macOS 26, where CGWindowListCreateImage is obsoleted. Over bare
desktop a generous region of that display is captured instead.

Quartz and Pillow are imported lazily, so this module loads anywhere and
its logic can be tested with fakes.
"""

from __future__ import annotations

import io
import os
import queue
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field

from screen_marks import (
    MAX_IMAGE_EDGE,
    Stroke,
    choose_window,
    desktop_region,
    display_containing,
    fit_long_edge,
    ink_shapes,
    mark_anchor,
    to_image,
    window_rect,
)

INK_RGB = (255, 59, 48)
BADGE_TEXT_RGB = (255, 255, 255)
SCREENCAPTURE_TIMEOUT = 5.0
_FONT_CANDIDATES = (
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
)


# ---------------------------------------------------------------------------
# Quartz helpers
# ---------------------------------------------------------------------------

def list_windows() -> list[dict]:
    """On-screen windows, front to back, as plain dicts."""
    import Quartz

    options = (
        Quartz.kCGWindowListOptionOnScreenOnly
        | Quartz.kCGWindowListExcludeDesktopElements
    )
    windows = Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID) or []
    result = []
    for window in windows:
        entry = {key: window[key] for key in window.keys()}
        bounds = entry.get("kCGWindowBounds")
        if bounds is not None:
            entry["kCGWindowBounds"] = {key: float(bounds[key]) for key in bounds.keys()}
        result.append(entry)
    return result


def list_displays() -> list[tuple[float, float, float, float]]:
    """Active displays in Quartz global points. Safe off the main thread."""
    import Quartz

    err, ids, count = Quartz.CGGetActiveDisplayList(16, None, None)
    if err:
        return []
    displays = []
    for display_id in list(ids)[:count]:
        bounds = Quartz.CGDisplayBounds(display_id)
        displays.append(
            (bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height)
        )
    return displays


def run_screencapture(args: list[str]) -> bytes:
    """Run `screencapture` with `args` and return the PNG it wrote."""
    directory = tempfile.mkdtemp(prefix="voice-type-capture-")
    try:
        path = os.path.join(directory, "capture.png")
        # -x: no shutter sound. -t png: the format we paste.
        subprocess.run(
            ["/usr/sbin/screencapture", "-x", "-t", "png", *args, path],
            check=True,
            timeout=SCREENCAPTURE_TIMEOUT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        with open(path, "rb") as f:
            return f.read()
    finally:
        shutil.rmtree(directory, ignore_errors=True)


# ---------------------------------------------------------------------------
# Capture and compositing
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class CaptureTarget:
    rect: tuple[float, float, float, float]
    args: list[str]
    description: str


def capture_target(stroke: Stroke, windows, displays, own_pid: int) -> CaptureTarget | None:
    """Decide what to capture for a mark: its window, or a desktop region."""
    anchor = mark_anchor(stroke)
    window = choose_window(windows, anchor, exclude_pids=[own_pid])
    if window is not None:
        number = int(window.get("kCGWindowNumber", 0))
        owner = window.get("kCGWindowOwnerName") or "window"
        # -o leaves the window's shadow out, so the ink offsets are exact.
        return CaptureTarget(window_rect(window), ["-o", "-l", str(number)], f"{owner} #{number}")
    display = display_containing(displays, anchor)
    if display is None:
        return None
    x, y, w, h = desktop_region(display, anchor)
    region = f"{round(x)},{round(y)},{round(w)},{round(h)}"
    return CaptureTarget((round(x), round(y), round(w), round(h)), ["-R", region], f"desktop {region}")


def _font(size: int):
    from PIL import ImageFont

    for path in _FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def draw_shapes(image, shapes) -> None:
    """Draw one mark's ink and number badge onto a Pillow RGBA image."""
    from PIL import ImageDraw

    draw = ImageDraw.Draw(image)
    width = max(1, round(shapes.width))
    if len(shapes.line) > 1:
        draw.line(shapes.line, fill=INK_RGB, width=width, joint="curve")
        # Round the ends; Pillow lines are square-capped.
        for x, y in (shapes.line[0], shapes.line[-1]):
            r = width / 2
            draw.ellipse((x - r, y - r, x + r, y + r), fill=INK_RGB)
    if shapes.arrowhead is not None:
        draw.polygon(list(shapes.arrowhead), fill=INK_RGB)
    if shapes.ring is not None:
        (cx, cy), r = shapes.ring
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=INK_RGB, width=width)
    (bx, by), br = shapes.badge
    draw.ellipse(
        (bx - br, by - br, bx + br, by + br),
        fill=INK_RGB,
        outline=BADGE_TEXT_RGB,
        width=max(1, round(br / 6)),
    )
    label = str(shapes.number)
    font = _font(max(8, round(br * 1.25)))
    draw.text((bx, by), label, fill=BADGE_TEXT_RGB, font=font, anchor="mm")


def composite_png(png: bytes, capture_rect, stroke: Stroke, max_edge: int = MAX_IMAGE_EDGE) -> bytes:
    """Draw `stroke` onto a capture of `capture_rect` and return a PNG."""
    from PIL import Image

    image = Image.open(io.BytesIO(png)).convert("RGBA")
    scale = image.width / capture_rect[2] if capture_rect[2] else 1.0
    shapes = ink_shapes(
        stroke,
        transform=lambda p: to_image(p, capture_rect, image.size),
        scale=scale,
    )
    draw_shapes(image, shapes)
    size = fit_long_edge(image.width, image.height, max_edge)
    if size != image.size:
        image = image.resize(size, Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=False)
    return out.getvalue()


def capture_mark(
    stroke: Stroke,
    *,
    own_pid: int,
    windows=None,
    displays=None,
    capture=None,
    composite=None,
) -> tuple[bytes, CaptureTarget] | None:
    windows = list_windows() if windows is None else windows
    displays = list_displays() if displays is None else displays
    capture = capture or run_screencapture
    composite = composite or composite_png
    target = capture_target(stroke, windows, displays, own_pid)
    if target is None:
        return None
    return composite(capture(target.args), target.rect, stroke), target


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

@dataclass
class CaptureSession:
    """One dictation's screenshots, filled in by the capture worker."""

    ident: int
    submitted: set = field(default_factory=set)
    paths: dict = field(default_factory=dict)
    permission_missing: bool = False
    done: threading.Condition = field(default_factory=threading.Condition)
    expected: set | None = None

    def wait(self, timeout: float) -> list[tuple[int, str]]:
        """Block until every expected mark is captured (or failed), then
        return (number, path) pairs in mark order."""
        import time

        deadline = time.monotonic() + timeout
        with self.done:
            while self.expected is not None and not self.expected <= set(self.paths):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.done.wait(remaining)
            return sorted((n, p) for n, p in self.paths.items() if p)


class MarkCapturer:
    """Queue marks from the tap thread and capture them on one worker."""

    def __init__(
        self,
        store,
        *,
        log,
        own_pid: int | None = None,
        capture=None,
        allowed=None,
        request=None,
    ) -> None:
        self._store = store
        self._log = log
        self._own_pid = os.getpid() if own_pid is None else own_pid
        self._capture = capture or (lambda stroke: capture_mark(stroke, own_pid=self._own_pid))
        self._allowed = allowed
        self._request = request
        self._requested = False
        self._queue: queue.SimpleQueue = queue.SimpleQueue()
        self._lock = threading.Lock()
        self._session: CaptureSession | None = None
        self._next_ident = 0
        self._thread: threading.Thread | None = None

    def begin(self) -> CaptureSession:
        with self._lock:
            self._next_ident += 1
            self._session = CaptureSession(self._next_ident)
            if self._thread is None:
                self._thread = threading.Thread(
                    target=self._worker, daemon=True, name="voice-type-mark-capture",
                )
                self._thread.start()
            return self._session

    def submit(self, stroke: Stroke) -> None:
        """Called on the event tap thread: no work beyond a queue put."""
        session = self._session
        if session is None:
            return
        with session.done:
            if stroke.number in session.submitted:
                return
            session.submitted.add(stroke.number)
        self._queue.put((session, stroke))

    def finish(self, strokes: list[Stroke]) -> CaptureSession | None:
        """Close the session at key-up. Any mark the tap thread hadn't
        handed over yet is queued now."""
        with self._lock:
            session, self._session = self._session, None
        if session is None:
            return None
        pending = []
        with session.done:
            session.expected = {s.number for s in strokes}
            for stroke in strokes:
                if stroke.number not in session.submitted:
                    session.submitted.add(stroke.number)
                    pending.append(stroke)
            session.done.notify_all()
        for stroke in pending:
            self._queue.put((session, stroke))
        return session

    def _permission_ok(self, session: CaptureSession) -> bool:
        if self._allowed is None or self._allowed():
            return True
        session.permission_missing = True
        if not self._requested:
            self._requested = True
            self._log(
                "Screen Recording permission is missing, so marks can't be "
                "captured. Asking macOS for it; allow Voice Type in System "
                "Settings > Privacy & Security > Screen & System Audio "
                "Recording, then restart Voice Type."
            )
            if self._request is not None:
                self._request()
        return False

    def _worker(self) -> None:
        while True:
            session, stroke = self._queue.get()
            path = None
            try:
                if self._permission_ok(session):
                    result = self._capture(stroke)
                    if result is None:
                        self._log(f"Mark {stroke.number}: nothing to capture.")
                    else:
                        png, target = result
                        path = self._store.save(png, stroke.number)
                        self._log(
                            f"Mark {stroke.number} ({stroke.kind}) captured from "
                            f"{target.description}: {path}"
                        )
            except Exception as error:
                self._log(f"Mark {stroke.number} capture failed: {error}")
            with session.done:
                session.paths[stroke.number] = path
                session.done.notify_all()


@dataclass
class DictationMarks:
    """The marks from one dictation, handed from key-up to finalization."""

    strokes: list
    session: CaptureSession | None
    # Monotonic time of audio sample 0, to turn mark times into audio times.
    audio_origin: float
    wait_timeout: float = 4.0
    _shots: list | None = None

    def screenshots(self) -> list[tuple[int, str]]:
        """(number, path) for every mark that was captured, waiting once."""
        if self._shots is None:
            self._shots = self.session.wait(self.wait_timeout) if self.session else []
        return self._shots

    @property
    def permission_missing(self) -> bool:
        return bool(self.session and self.session.permission_missing)

    def audio_times(self, numbers) -> list[float]:
        """When each numbered mark was finished, in seconds of audio."""
        ended = {stroke.number: stroke.ended_at for stroke in self.strokes}
        return [ended[n] - self.audio_origin for n in numbers]
