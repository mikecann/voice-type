import importlib.util
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "screen_marks.py"


def load_module():
    spec = importlib.util.spec_from_file_location("screen_marks", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sm = load_module()


def line(start, end, steps=20):
    return [
        (start[0] + (end[0] - start[0]) * i / steps, start[1] + (end[1] - start[1]) * i / steps)
        for i in range(steps + 1)
    ]


def circle(cx, cy, r, steps=36):
    import math
    return [
        (cx + r * math.cos(2 * math.pi * i / steps), cy + r * math.sin(2 * math.pi * i / steps))
        for i in range(steps + 1)
    ]


class ClassifyStrokeTests(unittest.TestCase):
    def test_a_click_with_a_little_wobble_is_a_point(self):
        self.assertEqual("point", sm.classify_stroke([(100, 100), (102, 101), (101, 103)]))

    def test_a_single_sample_is_a_point(self):
        self.assertEqual("point", sm.classify_stroke([(5, 5)]))

    def test_a_straight_drag_is_an_arrow(self):
        self.assertEqual("arrow", sm.classify_stroke(line((0, 0), (200, 80))))

    def test_a_slightly_shaky_line_is_still_an_arrow(self):
        points = [(x, 50 + (3 if i % 2 else -3)) for i, x in enumerate(range(0, 200, 10))]
        self.assertEqual("arrow", sm.classify_stroke(points))

    def test_a_circle_stays_freeform(self):
        self.assertEqual("freeform", sm.classify_stroke(circle(300, 300, 60)))

    def test_a_short_flick_is_not_an_arrow(self):
        self.assertEqual("freeform", sm.classify_stroke(line((0, 0), (20, 0))))

    def test_scrubbing_back_and_forth_along_a_line_is_not_an_arrow(self):
        points = line((0, 0), (200, 0)) + line((200, 0), (40, 0)) + line((40, 0), (200, 0))
        self.assertEqual("freeform", sm.classify_stroke(points))

    def test_an_l_shape_is_not_an_arrow(self):
        points = line((0, 0), (200, 0)) + line((200, 0), (200, 200))
        self.assertEqual("freeform", sm.classify_stroke(points))

    def test_arrowhead_points_back_from_the_tip(self):
        tip, left, right = sm.arrowhead(line((0, 0), (200, 0)), length=18)
        self.assertEqual((200, 0), tip)
        self.assertLess(left[0], 200)
        self.assertLess(right[0], 200)
        self.assertAlmostEqual(left[1], -right[1])

    def test_anchor_is_the_arrow_tip_and_the_circle_centre(self):
        arrow = sm.Stroke(line((0, 0), (200, 0)), 0, 1)
        ring = sm.Stroke(circle(300, 300, 60), 0, 1)
        click = sm.Stroke([(40, 50)], 0, 1)
        self.assertEqual((200, 0), sm.mark_anchor(arrow))
        x, y = sm.mark_anchor(ring)
        self.assertAlmostEqual(300, x, delta=1)
        self.assertAlmostEqual(300, y, delta=1)
        self.assertEqual((40, 50), sm.mark_anchor(click))

    def test_arrow_badge_sits_behind_the_tail(self):
        arrow = sm.Stroke(line((100, 100), (300, 100)), 0, 1)
        x, y = sm.badge_center(arrow)
        self.assertLess(x, 100)
        self.assertEqual(100, y)


def window(pid, x, y, w, h, *, layer=0, alpha=1.0, number=1):
    return {
        "kCGWindowOwnerPID": pid,
        "kCGWindowLayer": layer,
        "kCGWindowAlpha": alpha,
        "kCGWindowNumber": number,
        "kCGWindowBounds": {"X": x, "Y": y, "Width": w, "Height": h},
    }


class ChooseWindowTests(unittest.TestCase):
    def test_picks_the_frontmost_window_containing_the_point(self):
        windows = [
            window(10, 0, 0, 100, 100, number=1),
            window(11, 50, 50, 500, 500, number=2),
            window(12, 0, 0, 2000, 2000, number=3),
        ]
        self.assertEqual(2, sm.choose_window(windows, (200, 200))["kCGWindowNumber"])

    def test_skips_our_own_windows(self):
        windows = [
            window(99, 0, 0, 3000, 2000, number=1),  # the ink overlay
            window(11, 0, 0, 800, 600, number=2),
        ]
        chosen = sm.choose_window(windows, (100, 100), exclude_pids=[99])
        self.assertEqual(2, chosen["kCGWindowNumber"])

    def test_skips_menus_the_dock_and_invisible_windows(self):
        windows = [
            window(1, 0, 0, 800, 600, layer=25, number=1),
            window(2, 0, 0, 800, 600, alpha=0.0, number=2),
            window(3, 90, 90, 20, 20, number=3),  # a tooltip
            window(4, 0, 0, 800, 600, number=4),
        ]
        self.assertEqual(4, sm.choose_window(windows, (100, 100))["kCGWindowNumber"])

    def test_returns_none_over_bare_desktop(self):
        self.assertIsNone(sm.choose_window([window(4, 0, 0, 100, 100)], (500, 500)))

    def test_handles_windows_on_a_display_left_of_the_primary(self):
        windows = [window(4, -1920, 100, 1000, 800)]
        self.assertIsNotNone(sm.choose_window(windows, (-1500, 300)))


class CoordinateTests(unittest.TestCase):
    PRIMARY_H = 1117

    def test_primary_screen_flips_to_top_left(self):
        self.assertEqual(
            (0, 0, 1728, 1117),
            sm.appkit_frame_to_quartz((0, 0, 1728, 1117), self.PRIMARY_H),
        )

    def test_a_display_above_the_primary_has_negative_quartz_y(self):
        # AppKit: external 2560x1440 sitting on top of the laptop screen.
        self.assertEqual(
            (-400, -1440, 2560, 1440),
            sm.appkit_frame_to_quartz((-400, 1117, 2560, 1440), self.PRIMARY_H),
        )

    def test_a_display_below_and_left(self):
        self.assertEqual(
            (-1920, 1117, 1920, 1080),
            sm.appkit_frame_to_quartz((-1920, -1080, 1920, 1080), self.PRIMARY_H),
        )

    def test_view_coordinates_are_relative_to_their_screen(self):
        screen = sm.appkit_frame_to_quartz((-400, 1117, 2560, 1440), self.PRIMARY_H)
        self.assertEqual((500, 40), sm.quartz_to_view((100, -1400), screen))

    def test_retina_window_capture_doubles_offsets(self):
        rect = (200, 100, 800, 600)
        self.assertEqual((200, 100), sm.to_image((300, 150), rect, (1600, 1200)))

    def test_one_x_display_keeps_points_as_pixels(self):
        rect = (-1920, 1117, 1920, 1080)
        self.assertEqual((20, 30), sm.to_image((-1900, 1147), rect, (1920, 1080)))

    def test_long_edge_is_capped(self):
        self.assertEqual((2000, 1250), sm.fit_long_edge(3456, 2160))
        self.assertEqual((1250, 2000), sm.fit_long_edge(2160, 3456))
        self.assertEqual((800, 600), sm.fit_long_edge(800, 600))

    def test_display_lookup_and_nearest_fallback(self):
        displays = [(0, 0, 1728, 1117), (-1920, 0, 1920, 1080)]
        self.assertEqual(displays[1], sm.display_containing(displays, (-10, 10)))
        self.assertEqual(displays[0], sm.display_containing(displays, (2000, 10)))

    def test_desktop_region_stays_inside_its_display(self):
        self.assertEqual((0, 0, 800, 800), sm.desktop_region((0, 0, 1728, 1117), (10, 10)))
        self.assertEqual(
            (928, 317, 800, 800),
            sm.desktop_region((0, 0, 1728, 1117), (1720, 1110)),
        )
        self.assertEqual((0, 0, 600, 500), sm.desktop_region((0, 0, 600, 500), (300, 250)))


class InkShapesTests(unittest.TestCase):
    def test_ink_lands_where_the_mark_was_on_a_retina_window(self):
        stroke = sm.Stroke(line((300, 200), (500, 200)), 0, 1, number=3)
        rect = (200, 100, 800, 600)
        shapes = sm.ink_shapes(
            stroke,
            transform=lambda p: sm.to_image(p, rect, (1600, 1200)),
            scale=2.0,
        )
        self.assertEqual("arrow", shapes.kind)
        self.assertEqual((200, 200), shapes.line[0])
        # The line stops under the arrowhead instead of poking past its tip.
        self.assertLess(shapes.line[-1][0], 600)
        self.assertGreater(shapes.line[-1][0], 560)
        self.assertEqual((600, 200), shapes.arrowhead[0])
        self.assertEqual(sm.INK_WIDTH * 2, shapes.width)
        self.assertEqual(3, shapes.number)
        badge, radius = shapes.badge
        self.assertLess(badge[0], 200)
        self.assertEqual(sm.BADGE_RADIUS * 2, radius)

    def test_a_click_becomes_a_ring_without_a_line(self):
        shapes = sm.ink_shapes(sm.Stroke([(10, 10)], 0, 1, number=1))
        self.assertEqual([], shapes.line)
        self.assertEqual(((10, 10), sm.RING_RADIUS), shapes.ring)
        self.assertIsNone(shapes.arrowhead)


class MarkerPlacementTests(unittest.TestCase):
    WORDS = [
        sm.TimedText(0.0, 0.3, " This"),
        sm.TimedText(0.3, 0.6, " button"),
        sm.TimedText(0.6, 0.9, " is"),
        sm.TimedText(0.9, 1.4, " broken,"),
        sm.TimedText(2.0, 2.3, " and"),
        sm.TimedText(2.3, 2.6, " this"),
        sm.TimedText(2.6, 3.0, " one"),
        sm.TimedText(3.0, 3.4, " too."),
    ]
    SPOKEN = " ".join(w.text for w in WORDS)

    def place(self, final_text, mark_times, words=WORDS, segments=None, spoken=SPOKEN):
        counts = sm.spoken_word_counts(mark_times, words=words, segments=segments)
        numbers = list(range(1, len(mark_times) + 1))
        return sm.insert_markers(final_text, spoken, counts, numbers)

    def test_markers_follow_the_word_being_spoken(self):
        text = "This button is broken, and this one too."
        self.assertEqual(
            "This button [1] is broken, and this one [2] too.",
            self.place(text, [0.45, 2.8]),
        )

    def test_marker_goes_before_trailing_punctuation(self):
        text = "This button is broken, and this one too."
        self.assertEqual(
            "This button is broken [1], and this one too [2].",
            self.place(text, [1.6, 5.0]),
        )

    def test_marks_in_the_same_spot_share_it(self):
        text = "This button is broken, and this one too."
        self.assertEqual(
            "This button [1] [2] is broken, and this one too.",
            self.place(text, [0.4, 0.5]),
        )

    def test_a_mark_before_any_speech_goes_first(self):
        text = "This button is broken, and this one too."
        self.assertEqual(
            "[1] This button is broken, and this one too.",
            self.place(text, [-0.2]),
        )

    def test_survives_the_formatter_changing_case_and_punctuation(self):
        formatted = "This button is broken. And this one, too!"
        self.assertEqual(
            "This button is broken [1]. And this one [2], too!",
            self.place(formatted, [1.6, 2.8]),
        )

    def test_survives_a_correction_replacing_a_word(self):
        words = [
            sm.TimedText(0.0, 0.3, " the"),
            sm.TimedText(0.3, 0.6, " Q"),
            sm.TimedText(0.6, 0.9, " DA"),
            sm.TimedText(0.9, 1.2, " build"),
            sm.TimedText(1.2, 1.5, " fails"),
        ]
        spoken = " ".join(w.text for w in words)
        self.assertEqual(
            "the CUDA build [1] fails",
            self.place("the CUDA build fails", [1.0], words=words, spoken=spoken),
        )
        # A mark inside the corrected words lands just before them.
        self.assertEqual(
            "the [1] CUDA build fails",
            self.place("the CUDA build fails", [0.7], words=words, spoken=spoken),
        )

    def test_segment_timings_use_the_nearest_boundary(self):
        segments = [
            sm.TimedText(0.0, 1.4, "This button is broken,"),
            sm.TimedText(2.0, 3.4, "and this one too."),
        ]
        spoken = " ".join(s.text for s in segments)
        text = "This button is broken, and this one too."
        self.assertEqual(
            "This button is broken [1], and this one too [2].",
            self.place(text, [1.0, 3.1], words=None, segments=segments, spoken=spoken),
        )
        self.assertEqual(
            "[1] This button is broken, and this one too.",
            self.place(text, [0.3], words=None, segments=segments, spoken=spoken),
        )

    def test_without_timings_markers_are_appended(self):
        self.assertIsNone(sm.spoken_word_counts([1.0]))
        self.assertEqual(
            "Look at these. [1] [2]",
            sm.insert_markers("Look at these.", "", None, [1, 2]),
        )

    def test_no_words_means_just_markers(self):
        self.assertEqual("[1] [2]", sm.insert_markers("", "", [0, 0], [1, 2]))

    def test_no_marks_leaves_the_text_alone(self):
        self.assertEqual("Hello there.", sm.insert_markers("Hello there.", "hello there", [], []))


class TimingsFromSegmentsTests(unittest.TestCase):
    def test_reads_word_and_segment_timings(self):
        from types import SimpleNamespace as NS
        segments = [
            NS(text=" Hello there", start=0.0, end=1.0, words=[
                NS(start=0.0, end=0.4, word=" Hello"),
                NS(start=0.5, end=1.0, word=" there"),
            ]),
        ]
        words, timed = sm.timings_from_segments(segments)
        self.assertEqual([" Hello", " there"], [w.text for w in words])
        self.assertEqual([sm.TimedText(0.0, 1.0, "Hello there")], timed)

    def test_untimed_segments_give_nothing(self):
        from types import SimpleNamespace as NS
        self.assertEqual(([], []), sm.timings_from_segments([NS(text="hi")]))


class ScreenshotStoreTests(unittest.TestCase):
    def test_saves_and_prunes_only_its_own_expired_files(self):
        now = [datetime(2026, 10, 1, tzinfo=timezone.utc)]
        with tempfile.TemporaryDirectory() as tmp:
            store = sm.ScreenshotStore(pathlib.Path(tmp) / "screenshots", clock=lambda: now[0])
            old = store.save(b"old png", 1)
            now[0] += timedelta(days=6)
            recent = store.save(b"new png", 2)
            unrelated = pathlib.Path(tmp) / "screenshots" / "keep-me.png"
            unrelated.write_bytes(b"x")
            now[0] += timedelta(days=2)

            self.assertEqual(1, store.cleanup())
            self.assertFalse(pathlib.Path(old).exists())
            self.assertEqual(b"new png", pathlib.Path(recent).read_bytes())
            self.assertTrue(unrelated.exists())
            self.assertTrue(recent.endswith("_2.png"))

    def test_cleanup_without_a_folder_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = sm.ScreenshotStore(pathlib.Path(tmp) / "missing")
            self.assertEqual(0, store.cleanup())


if __name__ == "__main__":
    unittest.main()
