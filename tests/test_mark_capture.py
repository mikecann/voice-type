import importlib.util
import io
import pathlib
import sys
import threading
import time
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
        self.discarded = []

    def save(self, png, number):
        self.saved.append((number, png))
        return f"/shots/{len(self.saved)}.png"

    def discard(self, path):
        self.discarded.append(path)
        return True


def window_target(number, rect=(0, 0, 800, 600)):
    return mark_capture.CaptureTarget(rect, ["-o", "-l", str(number)], f"App #{number}", window=number)


def desktop_target(rect=(0, 0, 800, 800)):
    return mark_capture.CaptureTarget(rect, ["-R", "0,0,800,800"], "desktop 0,0,800,800")


class MarkCapturerTests(unittest.TestCase):
    def setUp(self):
        self.logs = []
        self.store = FakeStore()
        self.requests = []
        self.composited = []
        # Each mark lands on its own desktop region unless a test says
        # otherwise, so nothing groups by accident.
        self.targets = {}

    def capture(self, stroke):
        target = self.targets.get(stroke.number) or desktop_target((stroke.number, 0, 800, 800))
        return f"raw{stroke.number}".encode(), target

    def composite(self, raw, rect, strokes):
        self.composited.append((raw, rect, [s.number for s in strokes]))
        return b"png " + raw + b" " + bytes(str([s.number for s in strokes]), "ascii")

    def capturer(self, allowed=True, capture=None, composite=None):
        return mark_capture.MarkCapturer(
            self.store,
            log=self.logs.append,
            own_pid=1,
            capture=capture or self.capture,
            composite=composite or self.composite,
            allowed=lambda: allowed,
            request=lambda: self.requests.append(True),
        )

    def run_marks(self, numbers, submitted=None, **kwargs):
        capturer = self.capturer(**kwargs)
        capturer.begin()
        strokes = [arrow((0, 0), (100, 0), n) for n in numbers]
        for n in submitted or numbers:
            capturer.submit(strokes[numbers.index(n)])
        return capturer.finish(strokes).wait(2.0)

    def test_marks_are_captured_and_returned_in_order(self):
        capturer = self.capturer()
        capturer.begin()
        strokes = [arrow((0, 0), (100, 0), n) for n in (1, 2, 3)]
        capturer.submit(strokes[1])
        capturer.submit(strokes[0])
        session = capturer.finish(strokes)  # mark 3 was never handed over

        self.assertEqual(
            [(1, "/shots/2.png"), (2, "/shots/1.png"), (3, "/shots/3.png")],
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

    def test_two_marks_on_one_window_share_one_screenshot_with_both_drawn(self):
        self.targets = {1: window_target(42), 2: window_target(42)}
        shots = self.run_marks([1, 2])

        self.assertEqual([(1, "/shots/2.png"), (2, "/shots/2.png")], shots)
        # The second composite draws both marks onto the newest capture.
        self.assertEqual((b"raw2", (0, 0, 800, 600), [1, 2]), self.composited[-1])
        self.assertIn("Marks [1, 2] share App #42: one screenshot.", self.logs)

    def test_recompositing_replaces_the_groups_earlier_file(self):
        self.targets = {n: window_target(42) for n in (1, 2, 3)}
        shots = self.run_marks([1, 2, 3])

        self.assertEqual({"/shots/3.png"}, {path for _n, path in shots})
        self.assertEqual(["/shots/1.png", "/shots/2.png"], self.store.discarded)

    def test_marks_on_different_windows_get_separate_screenshots(self):
        self.targets = {1: window_target(42), 2: window_target(7)}
        shots = self.run_marks([1, 2])

        self.assertEqual([(1, "/shots/1.png"), (2, "/shots/2.png")], shots)
        self.assertEqual([[1], [2]], [numbers for _raw, _rect, numbers in self.composited])
        self.assertEqual([], self.store.discarded)

    def test_a_window_that_moved_between_marks_does_not_group(self):
        self.targets = {
            1: window_target(42, (0, 0, 800, 600)),
            2: window_target(42, (50, 0, 800, 600)),
        }
        shots = self.run_marks([1, 2])

        self.assertEqual([(1, "/shots/1.png"), (2, "/shots/2.png")], shots)
        self.assertEqual([], self.store.discarded)

    def test_desktop_captures_never_group(self):
        self.targets = {1: desktop_target(), 2: desktop_target()}
        shots = self.run_marks([1, 2])

        self.assertEqual([(1, "/shots/1.png"), (2, "/shots/2.png")], shots)
        self.assertEqual([[1], [2]], [numbers for _raw, _rect, numbers in self.composited])

    def test_marks_handed_over_out_of_order_still_group_and_draw_in_order(self):
        self.targets = {1: window_target(42), 2: window_target(42)}
        shots = self.run_marks([1, 2], submitted=[2, 1])

        self.assertEqual([(1, "/shots/2.png"), (2, "/shots/2.png")], shots)
        self.assertEqual((b"raw1", (0, 0, 800, 600), [1, 2]), self.composited[-1])
        self.assertEqual(1, self.store.saved[-1][0])  # named after its lowest mark

    def test_a_failed_recomposite_keeps_the_earlier_marks_screenshot(self):
        self.targets = {1: window_target(42), 2: window_target(42)}

        def composite(raw, rect, strokes):
            if len(strokes) > 1:
                raise RuntimeError("Pillow fell over")
            return self.composite(raw, rect, strokes)

        shots = self.run_marks([1, 2], composite=composite)
        self.assertEqual([(1, "/shots/1.png")], shots)
        self.assertEqual([], self.store.discarded)

    def test_a_late_recomposite_leaves_the_file_already_handed_out(self):
        self.targets = {1: window_target(42), 2: window_target(42)}
        release = threading.Event()

        def capture(stroke):
            if stroke.number == 2:
                release.wait(2.0)
            return self.capture(stroke)

        capturer = self.capturer(capture=capture)
        capturer.begin()
        strokes = [arrow((0, 0), (100, 0), n) for n in (1, 2)]
        session = capturer.finish(strokes)
        # Mark 2 is still capturing when finalization gives up waiting.
        self.assertEqual([(1, "/shots/1.png")], session.wait(0.2))
        release.set()
        deadline = time.monotonic() + 2.0
        while len(self.store.saved) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.05)
        self.assertEqual(2, len(self.store.saved))
        self.assertEqual([], self.store.discarded)

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
            return self.capture(stroke)

        shots = self.run_marks([1, 2], capture=capture)
        self.assertEqual([(2, "/shots/1.png")], shots)
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

    def assertColor(self, expected, actual):
        # Quantizing averages similar colours, so allow a level or two.
        self.assertEqual(len(expected), len(actual))
        for want, got in zip(expected, actual):
            self.assertLessEqual(abs(want - got), 2, f"{actual} is not {expected}")

    def composite(self, png, rect, strokes):
        # Converting the palette PNG to RGBA, not RGB, keeps Pillow from
        # warning about its byte-wise transparency.
        return Image.open(io.BytesIO(mark_capture.composite_png(png, rect, strokes))).convert("RGBA")

    def test_ink_lands_at_the_right_retina_pixels(self):
        # Window at (200, 100) points, 400x300 points, captured at 2x.
        stroke = arrow((250, 200), (450, 200))
        result = self.composite(self.png((800, 600)), (200, 100, 400, 300), [stroke])

        self.assertEqual((800, 600), result.size)
        # Midway along the arrow: (350, 200) points -> (300, 200) pixels.
        self.assertColor(mark_capture.INK_RGB + (255,), result.getpixel((300, 200)))
        # Well away from the ink stays white.
        self.assertColor((255, 255, 255, 255), result.getpixel((300, 400)))

    def test_every_mark_in_a_group_is_drawn_on_one_image(self):
        strokes = [arrow((250, 150), (450, 150), 1), arrow((250, 300), (450, 300), 2)]
        result = self.composite(self.png((800, 600)), (200, 100, 400, 300), strokes)

        self.assertColor(mark_capture.INK_RGB + (255,), result.getpixel((300, 100)))
        self.assertColor(mark_capture.INK_RGB + (255,), result.getpixel((300, 400)))
        self.assertColor((255, 255, 255, 255), result.getpixel((300, 250)))

    def test_output_is_a_small_palette_png_that_keeps_transparent_corners(self):
        from PIL import ImageDraw

        capture = Image.new("RGBA", (3456, 2234), (255, 255, 255, 255))
        corners = Image.new("L", capture.size, 0)
        ImageDraw.Draw(corners).rounded_rectangle(
            (0, 0, capture.width - 1, capture.height - 1), radius=40, fill=255,
        )
        capture.putalpha(corners)
        out = io.BytesIO()
        capture.save(out, format="PNG")
        png = mark_capture.composite_png(
            out.getvalue(), (0, 0, 1728, 1117), [Stroke([(800, 500)], 0, 1, number=1)],
        )

        result = Image.open(io.BytesIO(png))
        self.assertEqual("P", result.mode)
        self.assertEqual(1568, max(result.size))
        self.assertEqual(0, result.convert("RGBA").getpixel((1, 1))[3])
        # Antialiased corners mustn't leave the body of the window see-through.
        self.assertEqual(255, result.convert("RGBA").getpixel((700, 700))[3])


class DictationMarksTests(unittest.TestCase):
    class Session:
        permission_missing = False

        def __init__(self, shots):
            self.shots = shots
            self.timeouts = []

        def wait(self, timeout):
            self.timeouts.append(timeout)
            return self.shots

    def strokes(self, numbers=(1, 2, 3)):
        return [
            Stroke(points=[(0, 0)], started_at=0, ended_at=1, number=n)
            for n in numbers
        ]

    def test_waits_longer_for_more_marks_and_logs_any_left_out(self):
        session = self.Session([(1, "/a.png"), (3, "/c.png")])
        logs = []
        marks = mark_capture.DictationMarks(self.strokes(), session, 0.0, log=logs.append)

        self.assertEqual([1, 3], marks.numbers())
        self.assertEqual(["/a.png", "/c.png"], marks.image_paths())
        self.assertEqual([7.0], session.timeouts)
        self.assertEqual(["Mark(s) [2] have no screenshot to paste."], logs)

    def test_shared_screenshots_are_pasted_once_in_order_of_their_lowest_mark(self):
        # Marks 1 and 3 share a window; mark 2 is on another one.
        session = self.Session([(1, "/one-and-three.png"), (2, "/two.png"), (3, "/one-and-three.png")])
        marks = mark_capture.DictationMarks(self.strokes(), session, 0.0)

        self.assertEqual([1, 2, 3], marks.numbers())
        self.assertEqual(["/one-and-three.png", "/two.png"], marks.image_paths())

    def test_without_a_session_there_is_nothing_to_paste(self):
        marks = mark_capture.DictationMarks(self.strokes(), None, 0.0)
        self.assertEqual([], marks.numbers())
        self.assertEqual([], marks.image_paths())


if __name__ == "__main__":
    unittest.main()
