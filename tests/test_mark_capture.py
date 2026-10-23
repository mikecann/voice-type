import importlib.util
import io
import pathlib
import sys
import unittest

TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import mark_capture
from screen_marks import Stroke

try:
    from PIL import Image
except ImportError:  # Pillow is a macOS runtime dependency, not a test one.
    Image = None


def window(pid, number, x, y, w, h):
    return {
        "kCGWindowOwnerPID": pid,
        "kCGWindowOwnerName": f"App{pid}",
        "kCGWindowLayer": 0,
        "kCGWindowNumber": number,
        "kCGWindowBounds": {"X": x, "Y": y, "Width": w, "Height": h},
    }


def arrow(start, end, number=1):
    points = [
        (start[0] + (end[0] - start[0]) * i / 10, start[1] + (end[1] - start[1]) * i / 10)
        for i in range(11)
    ]
    return Stroke(points, 0.0, 1.0, number=number)


class CaptureTargetTests(unittest.TestCase):
    DISPLAYS = [(0, 0, 1728, 1117), (1728, -200, 2560, 1440)]

    def test_captures_the_window_under_the_arrow_tip_without_its_shadow(self):
        windows = [
            window(99, 1, 0, 0, 4288, 1440),  # our ink overlay
            window(10, 42, 100, 100, 800, 600),
        ]
        target = mark_capture.capture_target(
            arrow((50, 50), (300, 300)), windows, self.DISPLAYS, own_pid=99,
        )
        self.assertEqual(["-o", "-l", "42"], target.args)
        self.assertEqual((100, 100, 800, 600), target.rect)

    def test_bare_desktop_captures_a_region_of_that_display(self):
        target = mark_capture.capture_target(
            Stroke([(2000, 0)], 0, 1, number=1), [], self.DISPLAYS, own_pid=99,
        )
        self.assertEqual(["-R", "1728,-200,800,800"], target.args)
        self.assertEqual((1728, -200, 800, 800), target.rect)

    def test_nothing_to_capture_without_displays(self):
        self.assertIsNone(
            mark_capture.capture_target(Stroke([(5, 5)], 0, 1), [], [], own_pid=1)
        )


class FakeStore:
    def __init__(self):
        self.saved = []

    def save(self, png, number):
        self.saved.append((number, png))
        return f"/shots/{number}.png"


class MarkCapturerTests(unittest.TestCase):
    def setUp(self):
        self.logs = []
        self.store = FakeStore()
        self.requests = []

    def capturer(self, allowed=True, capture=None):
        return mark_capture.MarkCapturer(
            self.store,
            log=self.logs.append,
            own_pid=1,
            capture=capture or (lambda s: (f"png{s.number}".encode(), mark_capture.CaptureTarget((0, 0, 1, 1), [], "fake"))),
            allowed=lambda: allowed,
            request=lambda: self.requests.append(True),
        )

    def test_marks_are_captured_and_returned_in_order(self):
        capturer = self.capturer()
        capturer.begin()
        strokes = [arrow((0, 0), (100, 0), n) for n in (1, 2, 3)]
        capturer.submit(strokes[1])
        capturer.submit(strokes[0])
        session = capturer.finish(strokes)  # mark 3 was never handed over

        self.assertEqual(
            [(1, "/shots/1.png"), (2, "/shots/2.png"), (3, "/shots/3.png")],
            session.wait(2.0),
        )
        self.assertFalse(session.permission_missing)

    def test_a_mark_handed_over_twice_is_captured_once(self):
        capturer = self.capturer()
        capturer.begin()
        stroke = arrow((0, 0), (100, 0))
        capturer.submit(stroke)
        capturer.submit(stroke)
        capturer.finish([stroke]).wait(2.0)
        self.assertEqual(1, len(self.store.saved))

    def test_missing_permission_asks_once_and_captures_nothing(self):
        capturer = self.capturer(allowed=False)
        for _ in range(2):
            capturer.begin()
            stroke = arrow((0, 0), (100, 0))
            capturer.submit(stroke)
            session = capturer.finish([stroke])
            self.assertEqual([], session.wait(2.0))
            self.assertTrue(session.permission_missing)
        self.assertEqual([True], self.requests)
        self.assertEqual([], self.store.saved)

    def test_a_failed_capture_is_logged_and_skipped(self):
        def capture(stroke):
            if stroke.number == 1:
                raise RuntimeError("screencapture exited 1")
            return b"png", mark_capture.CaptureTarget((0, 0, 1, 1), [], "fake")

        capturer = self.capturer(capture=capture)
        capturer.begin()
        strokes = [arrow((0, 0), (100, 0), n) for n in (1, 2)]
        session = capturer.finish(strokes)
        self.assertEqual([(2, "/shots/2.png")], session.wait(2.0))
        self.assertTrue(any("capture failed" in line for line in self.logs))

    def test_no_session_means_nothing_is_queued(self):
        capturer = self.capturer()
        capturer.submit(arrow((0, 0), (100, 0)))
        self.assertIsNone(capturer.finish([]))


@unittest.skipIf(Image is None, "Pillow not installed")
class CompositeTests(unittest.TestCase):
    def png(self, size, color=(255, 255, 255, 255)):
        out = io.BytesIO()
        Image.new("RGBA", size, color).save(out, format="PNG")
        return out.getvalue()

    def test_ink_lands_at_the_right_retina_pixels(self):
        # Window at (200, 100) points, 400x300 points, captured at 2x.
        stroke = arrow((250, 200), (450, 200))
        result = Image.open(io.BytesIO(
            mark_capture.composite_png(self.png((800, 600)), (200, 100, 400, 300), stroke)
        )).convert("RGB")

        self.assertEqual((800, 600), result.size)
        # Midway along the arrow: (350, 200) points -> (300, 200) pixels.
        self.assertEqual(mark_capture.INK_RGB, result.getpixel((300, 200)))
        # Well away from the ink stays white.
        self.assertEqual((255, 255, 255), result.getpixel((300, 400)))

    def test_large_captures_are_downscaled(self):
        stroke = Stroke([(10, 10)], 0, 1, number=1)
        result = Image.open(io.BytesIO(
            mark_capture.composite_png(self.png((3456, 2234)), (0, 0, 1728, 1117), stroke)
        ))
        self.assertEqual(2000, max(result.size))


if __name__ == "__main__":
    unittest.main()
