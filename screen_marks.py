"""Draw while dictating: the plain-Python half of screen marks.

While the push-to-talk key is held on macOS, mouse drags become ink. Each
mark becomes an annotated screenshot and a numbered marker in the text. This
module holds everything that doesn't need a Mac, so it can be tested anywhere:
stroke classification, window choice, coordinate conversion, where ink lands
in a captured image, marker placement, and screenshot retention.

Coordinates are Quartz global points unless a name says otherwise: the origin
is the top-left corner of the primary display, y grows downwards, and one
unit is a point, not a pixel. A Retina capture has two pixels per point.
"""

from __future__ import annotations

import difflib
import math
import os
import re
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_MARKS = 10
# Claude shrinks anything with a longer edge than this before the model sees
# it, so sending more pixels only makes the paste bigger.
MAX_IMAGE_EDGE = 1568
SCREENSHOT_RETENTION_DAYS = 7

# A click wobbles a few points; anything inside this is a point mark.
POINT_MARK_MAX_TRAVEL = 6.0
# A drag counts as a straight arrow when it's long enough, nothing bulges far
# off the line between its ends, and it doesn't double back on itself. The
# path length ratio is loose because hand jitter adds length to any line.
ARROW_MIN_LENGTH = 30.0
ARROW_MIN_STRAIGHTNESS = 0.75
ARROW_MAX_BULGE_RATIO = 0.12
ARROW_MIN_BULGE = 8.0

# Ink sizes in points; captures scale them by the image's pixels per point.
INK_WIDTH = 4.0
RING_RADIUS = 14.0
ARROWHEAD_LENGTH = 20.0
BADGE_RADIUS = 11.0

# Half the size of the region captured around a mark on bare desktop.
DESKTOP_REGION_HALF = 400.0
# Windows smaller than this are tooltips, cursors and the like.
MIN_WINDOW_EDGE = 40.0

Point = tuple[float, float]
Rect = tuple[float, float, float, float]  # x, y, width, height


@dataclass
class Stroke:
    """One mouse-down to mouse-up, in Quartz global points."""

    points: list[Point]
    started_at: float
    ended_at: float
    number: int = 0
    kind: str = field(default="")

    def __post_init__(self) -> None:
        if not self.kind and self.points:
            self.kind = classify_stroke(self.points)


# ---------------------------------------------------------------------------
# Stroke shape
# ---------------------------------------------------------------------------

def _distance(a: Point, b: Point) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def path_length(points: list[Point]) -> float:
    return sum(_distance(a, b) for a, b in zip(points, points[1:]))


def _distance_to_line(p: Point, a: Point, b: Point) -> float:
    length = _distance(a, b)
    if length == 0:
        return _distance(p, a)
    return abs((b[0] - a[0]) * (a[1] - p[1]) - (a[0] - p[0]) * (b[1] - a[1])) / length


def classify_stroke(points: list[Point]) -> str:
    """Return "point", "arrow" or "freeform" for one stroke."""
    if not points:
        return "point"
    start = points[0]
    if max(_distance(start, p) for p in points) <= POINT_MARK_MAX_TRAVEL:
        return "point"
    end = points[-1]
    chord = _distance(start, end)
    length = path_length(points)
    if chord < ARROW_MIN_LENGTH or length == 0:
        return "freeform"
    if chord / length < ARROW_MIN_STRAIGHTNESS:
        return "freeform"
    bulge = max(_distance_to_line(p, start, end) for p in points)
    if bulge > max(ARROW_MIN_BULGE, chord * ARROW_MAX_BULGE_RATIO):
        return "freeform"
    return "arrow"


def arrowhead(points: list[Point], length: float = ARROWHEAD_LENGTH) -> tuple[Point, Point, Point]:
    """Return (tip, left barb, right barb) for an arrow ending at the last point.

    The direction comes from a point about two head lengths back along the
    path rather than the last segment, since the final few mouse samples of a
    drag often wobble.
    """
    tip = points[-1]
    base = points[0]
    for p in reversed(points):
        if _distance(p, tip) >= length * 2:
            base = p
            break
    angle = math.atan2(tip[1] - base[1], tip[0] - base[0])
    spread = math.radians(28)
    left = (
        tip[0] - length * math.cos(angle - spread),
        tip[1] - length * math.sin(angle - spread),
    )
    right = (
        tip[0] - length * math.cos(angle + spread),
        tip[1] - length * math.sin(angle + spread),
    )
    return tip, left, right


def stroke_bounds(points: list[Point]) -> Rect:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def mark_anchor(stroke: Stroke) -> Point:
    """The spot that decides which window a mark belongs to.

    An arrow points at its tip, so that's what matters. A click is its own
    point. A circle or scribble is about whatever it surrounds.
    """
    if stroke.kind == "point":
        return stroke.points[0]
    if stroke.kind == "arrow":
        return stroke.points[-1]
    x, y, w, h = stroke_bounds(stroke.points)
    return x + w / 2, y + h / 2


def badge_center(stroke: Stroke, radius: float = BADGE_RADIUS) -> Point:
    """Where the number badge sits, just clear of the mark itself."""
    gap = radius * 1.4
    if stroke.kind == "point":
        x, y = stroke.points[0]
        offset = RING_RADIUS + gap * 0.6
        return x + offset, y - offset
    if stroke.kind == "arrow":
        # Behind the tail, so it never covers what the arrow points at.
        start, end = stroke.points[0], stroke.points[-1]
        length = _distance(start, end) or 1.0
        ux, uy = (end[0] - start[0]) / length, (end[1] - start[1]) / length
        return start[0] - ux * gap, start[1] - uy * gap
    x, y, _w, _h = stroke_bounds(stroke.points)
    return x - gap * 0.7, y - gap * 0.7


# ---------------------------------------------------------------------------
# Windows and displays
# ---------------------------------------------------------------------------

def rect_contains(rect: Rect, point: Point) -> bool:
    x, y, w, h = rect
    return x <= point[0] < x + w and y <= point[1] < y + h


def window_rect(window: dict) -> Rect:
    bounds = window.get("kCGWindowBounds") or {}
    return (
        float(bounds.get("X", 0)),
        float(bounds.get("Y", 0)),
        float(bounds.get("Width", 0)),
        float(bounds.get("Height", 0)),
    )


def choose_window(windows, point: Point, exclude_pids=()) -> dict | None:
    """Return the frontmost normal window under `point`.

    `windows` is CGWindowListCopyWindowInfo's list, which is ordered front
    to back. Layer 0 is where normal app windows live; menus, the Dock and
    status items sit on other layers. Our own windows (the pill and the ink)
    are skipped by process id.
    """
    excluded = {int(pid) for pid in exclude_pids}
    for window in windows or []:
        if int(window.get("kCGWindowLayer", 0)) != 0:
            continue
        if float(window.get("kCGWindowAlpha", 1.0)) <= 0:
            continue
        if int(window.get("kCGWindowOwnerPID", -1)) in excluded:
            continue
        rect = window_rect(window)
        if rect[2] < MIN_WINDOW_EDGE or rect[3] < MIN_WINDOW_EDGE:
            continue
        if rect_contains(rect, point):
            return window
    return None


def display_containing(displays: list[Rect], point: Point) -> Rect | None:
    """The display under `point`, or the nearest one if it's off every display."""
    if not displays:
        return None
    for display in displays:
        if rect_contains(display, point):
            return display

    def gap(display: Rect) -> float:
        x, y, w, h = display
        dx = max(x - point[0], 0, point[0] - (x + w))
        dy = max(y - point[1], 0, point[1] - (y + h))
        return math.hypot(dx, dy)

    return min(displays, key=gap)


def desktop_region(display: Rect, point: Point, half: float = DESKTOP_REGION_HALF) -> Rect:
    """A generous box around `point`, slid to stay inside its display."""
    dx, dy, dw, dh = display
    w = min(half * 2, dw)
    h = min(half * 2, dh)
    x = min(max(point[0] - w / 2, dx), dx + dw - w)
    y = min(max(point[1] - h / 2, dy), dy + dh - h)
    return x, y, w, h


def appkit_frame_to_quartz(frame: Rect, primary_height: float) -> Rect:
    """Convert an AppKit screen/window frame to Quartz global coordinates.

    AppKit puts the origin at the bottom-left of the primary display with y
    growing upwards. Quartz puts it at the top-left with y growing down. Both
    use the primary display's height as the flip line, even for frames on
    other displays.
    """
    x, y, w, h = frame
    return x, primary_height - y - h, w, h


def quartz_to_view(point: Point, screen_rect: Rect) -> Point:
    """Map a Quartz global point into a flipped view covering `screen_rect`."""
    return point[0] - screen_rect[0], point[1] - screen_rect[1]


def to_image(point: Point, capture_rect: Rect, image_size: tuple[int, int]) -> Point:
    """Map a Quartz global point into pixel coordinates of a captured image.

    The scale comes from the image itself rather than the display's backing
    factor, so 1x displays, Retina displays and a window straddling both all
    come out right.
    """
    rx, ry, rw, rh = capture_rect
    sx = image_size[0] / rw if rw else 1.0
    sy = image_size[1] / rh if rh else 1.0
    return (point[0] - rx) * sx, (point[1] - ry) * sy


def fit_long_edge(width: int, height: int, max_edge: int = MAX_IMAGE_EDGE) -> tuple[int, int]:
    longest = max(width, height)
    if longest <= max_edge:
        return width, height
    scale = max_edge / longest
    return max(1, round(width * scale)), max(1, round(height * scale))


@dataclass(frozen=True)
class InkShapes:
    """Everything to draw for one mark, already in the target's coordinates."""

    kind: str
    line: list[Point]
    arrowhead: tuple[Point, Point, Point] | None
    ring: tuple[Point, float] | None
    badge: tuple[Point, float]
    width: float
    number: int


def ink_shapes(stroke: Stroke, transform=None, scale: float = 1.0) -> InkShapes:
    """Lay out one mark's ink, mapping points through `transform`.

    `scale` is pixels per point, so ink and badges keep the same apparent
    size on Retina captures as they had on screen.
    """
    if transform is None:
        def transform(p):
            return p
    line = [transform(p) for p in stroke.points]
    head = None
    ring = None
    if stroke.kind == "arrow":
        tip, left, right = arrowhead(stroke.points)
        head = (transform(tip), transform(left), transform(right))
        # Stop the line at the head's base, or its round cap pokes out past
        # the tip.
        base = ((left[0] + right[0]) / 2, (left[1] + right[1]) / 2)
        line = line[:-1] + [transform(base)]
    if stroke.kind == "point":
        ring = (transform(stroke.points[0]), RING_RADIUS * scale)
        line = []
    return InkShapes(
        kind=stroke.kind,
        line=line,
        arrowhead=head,
        ring=ring,
        badge=(transform(badge_center(stroke)), BADGE_RADIUS * scale),
        width=INK_WIDTH * scale,
        number=stroke.number,
    )


# ---------------------------------------------------------------------------
# Markers in the text
#
# Markers are placed after the formatter has run, never sent through it. The
# LLM formatter is free to tidy punctuation and casing, and the validator
# only checks that it kept most of the words. Asking it to keep "[1]" in the
# right place would be one more thing for a 0.5B model to get wrong, and a
# rejected format would throw away the cleanup too. Instead the timed words
# from the speech model are aligned to the final text word by word, which
# survives corrections, casing and punctuation changes.
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(r"\S+")
_TRAILING_PUNCTUATION = ".,!?;:)]}\"'”’…"


@dataclass(frozen=True)
class TimedText:
    """A word or segment from the speech model, timed in seconds of audio."""

    start: float
    end: float
    text: str


def _normalize(token: str) -> str:
    return re.sub(r"[^\w]", "", token.casefold())


def _words(text: str) -> list[str]:
    return [t for t in (_normalize(t) for t in text.split()) if t]


def timings_from_segments(segments) -> tuple[list[TimedText], list[TimedText]]:
    """Pull word and segment timings out of a speech model's segments.

    Works with faster-whisper segments and MlxSegment alike. Models that
    don't time anything (Parakeet) give two empty lists.
    """
    words: list[TimedText] = []
    timed_segments: list[TimedText] = []
    for segment in segments:
        text = str(getattr(segment, "text", "") or "").strip()
        start = getattr(segment, "start", None)
        end = getattr(segment, "end", None)
        if text and start is not None and end is not None and end > 0:
            timed_segments.append(TimedText(float(start), float(end), text))
        for word in getattr(segment, "words", None) or []:
            word_text = str(getattr(word, "word", "") or "")
            if word_text.strip():
                words.append(TimedText(float(word.start), float(word.end), word_text))
    return words, timed_segments


def spoken_word_counts(
    mark_times: list[float],
    *,
    words: list[TimedText] | None = None,
    segments: list[TimedText] | None = None,
) -> list[int] | None:
    """For each mark, how many transcribed words came before it.

    With word timings, a mark goes after the word being spoken when it was
    finished. With only segment timings, it goes at the nearest segment
    boundary. Returns None when there's no timing at all.
    """
    if words:
        counts = []
        for t in mark_times:
            spoken = [w for w in words if w.start <= t]
            counts.append(sum(len(_words(w.text)) for w in spoken))
        return counts
    if segments:
        boundaries = [(segments[0].start, 0)]
        total = 0
        for segment in segments:
            total += len(_words(segment.text))
            boundaries.append((segment.end, total))
        return [min(boundaries, key=lambda b: (abs(b[0] - t), -b[1]))[1] for t in mark_times]
    return None


def _token_spans(text: str) -> list[tuple[int, int, str]]:
    return [(m.start(), m.end(), _normalize(m.group())) for m in _TOKEN_RE.finditer(text)]


def _insertion_offset(text: str, end: int) -> int:
    """Step back over closing punctuation so "button." becomes "button [1]."."""
    while end > 0 and text[end - 1] in _TRAILING_PUNCTUATION:
        end -= 1
    return end


def marker_text(numbers: list[int]) -> str:
    return " ".join(f"[{n}]" for n in numbers)


def append_markers(text: str, numbers: list[int]) -> str:
    if not numbers:
        return text
    if not text.strip():
        return marker_text(numbers)
    return f"{text.rstrip()} {marker_text(numbers)}"


def insert_markers(
    final_text: str,
    spoken_text: str,
    word_counts: list[int] | None,
    numbers: list[int],
) -> str:
    """Put "[n]" markers into `final_text` after the counted spoken words.

    `spoken_text` is what the timings describe (the raw transcript). Its words
    are aligned to `final_text`, so corrections and formatting don't throw
    the markers off. Without counts, markers are appended at the end.
    """
    if not numbers:
        return final_text
    if word_counts is None or not final_text.strip():
        return append_markers(final_text, numbers)

    spoken = _words(spoken_text)
    final_tokens = [t for t in _token_spans(final_text) if t[2]]
    matcher = difflib.SequenceMatcher(None, spoken, [t[2] for t in final_tokens], autojunk=False)
    # spoken word index -> final token index, carrying the last match forward
    # over words the formatter or corrections replaced.
    mapped: list[int] = []
    matches = {}
    for block in matcher.get_matching_blocks():
        for i in range(block.size):
            matches[block.a + i] = block.b + i
    last = -1
    for i in range(len(spoken)):
        last = matches.get(i, last)
        mapped.append(last)

    groups: dict[int, list[int]] = {}
    for count, number in zip(word_counts, numbers):
        if count <= 0:
            token = -1
        elif count >= len(spoken):
            token = len(final_tokens) - 1
        else:
            token = mapped[count - 1]
        groups.setdefault(token, []).append(number)

    pieces = []
    cursor = 0
    for token in sorted(groups):
        label = marker_text(groups[token])
        if token < 0:
            pieces.append(f"{label} ")
            continue
        offset = _insertion_offset(final_text, final_tokens[token][1])
        if offset <= final_tokens[token][0]:
            offset = final_tokens[token][1]
        pieces.append(final_text[cursor:offset])
        pieces.append(f" {label}")
        cursor = offset
    pieces.append(final_text[cursor:])
    return "".join(pieces)


# ---------------------------------------------------------------------------
# Screenshot files
# ---------------------------------------------------------------------------

_SCREENSHOT_FILE = re.compile(r"^(\d{8}T\d{12}Z)_[0-9a-f]{32}_\d+\.png(\.tmp)?$")


class ScreenshotStore:
    """Annotated mark screenshots, deleted after a week.

    Follows RecordingArchive: the capture time is in the file name, so
    cleanup doesn't trust mutable mtimes, and files it didn't write are
    never touched.
    """

    def __init__(self, path, *, retention_days=SCREENSHOT_RETENTION_DAYS, clock=None):
        self.path = Path(path)
        self.retention_days = retention_days
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()

    def save(self, png: bytes, number: int) -> str:
        now = self._clock().astimezone(timezone.utc)
        name = f'{now.strftime("%Y%m%dT%H%M%S%fZ")}_{uuid.uuid4().hex}_{int(number)}.png'
        target = self.path / name
        temporary = target.with_suffix(".png.tmp")
        with self._lock:
            self.path.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, "wb") as output:
                    output.write(png)
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
        return str(target)

    def discard(self, path) -> bool:
        """Delete a screenshot this store saved, such as one replaced by a
        newer composite of the same window. Anything else is left alone."""
        target = Path(path)
        if target.parent != self.path or not _SCREENSHOT_FILE.fullmatch(target.name):
            return False
        with self._lock:
            try:
                target.unlink()
            except OSError:
                return False
        return True

    def cleanup(self) -> int:
        cutoff = self._clock().astimezone(timezone.utc) - timedelta(days=self.retention_days)
        removed = 0
        with self._lock:
            if not self.path.exists():
                return removed
            for path in self.path.iterdir():
                match = _SCREENSHOT_FILE.fullmatch(path.name)
                if not match:
                    continue
                try:
                    created = datetime.strptime(match[1], "%Y%m%dT%H%M%S%fZ").replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if created < cutoff:
                    path.unlink(missing_ok=True)
                    removed += 1
        return removed
