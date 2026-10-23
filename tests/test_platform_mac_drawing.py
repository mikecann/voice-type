import importlib.util
import pathlib
import sys
import unittest

TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "platform_mac.py"
for path in (TOOLS_DIR, TOOLS_DIR / "tests"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from test_platform_mac_clipboard import FakePasteboard, FakePasteboardItem


def load_module():
    spec = importlib.util.spec_from_file_location("platform_mac_drawing", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


class InkTrackerTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.clock = Clock()
        self.finished = []
        self.ink = self.module.MacInkTracker(
            clock=self.clock, max_marks=3, on_stroke=self.finished.append,
        )

    def drag(self, start, end):
        results = [self.ink.handle_mouse("down", *start)]
        self.clock.now += 0.1
        results.append(self.ink.handle_mouse("drag", (start[0] + end[0]) / 2, (start[1] + end[1]) / 2))
        results.append(self.ink.handle_mouse("drag", *end))
        self.clock.now += 0.1
        results.append(self.ink.handle_mouse("up", *end))
        return results

    def test_mouse_passes_through_without_a_session(self):
        self.assertEqual((False, False), self.ink.handle_mouse("down", 1, 1))
        self.assertEqual((False, False), self.ink.handle_mouse("up", 1, 1))
        self.assertFalse(self.ink.needs_tap())

    def test_every_button_event_is_swallowed_during_a_session(self):
        self.ink.begin()
        results = self.drag((0, 0), (100, 0))
        self.assertTrue(all(r == (True, True) for r in results))

    def test_a_drag_already_under_way_at_key_down_finishes_in_the_app(self):
        # The app saw this drag's mouse-down, so it must see the rest of it,
        # or it's left holding a button that was let go long ago.
        self.ink.begin()
        self.assertEqual((False, True), self.ink.handle_mouse("drag", 5, 5))
        self.assertEqual((False, True), self.ink.handle_mouse("up", 5, 5))
        self.assertEqual([], self.ink.take_strokes())
        # The next click is ours again.
        self.assertEqual((True, True), self.ink.handle_mouse("down", 9, 9))

    def test_each_drag_becomes_a_numbered_stroke(self):
        self.ink.begin()
        self.drag((0, 0), (100, 0))
        self.ink.handle_mouse("down", 300, 300)
        self.ink.handle_mouse("up", 301, 300)

        strokes = self.ink.take_strokes()
        self.assertEqual([1, 2], [s.number for s in strokes])
        self.assertEqual(["arrow", "point"], [s.kind for s in strokes])
        self.assertEqual([1, 2], [s.number for s in self.finished])
        self.assertAlmostEqual(100.2, strokes[0].ended_at)
        self.assertAlmostEqual(100.0, strokes[0].started_at)

    def test_marks_are_capped(self):
        self.ink.begin()
        for i in range(5):
            self.drag((0, i * 50), (100, i * 50))
        self.assertEqual(3, len(self.ink.take_strokes()))

    def test_release_mid_drag_ends_the_mark_and_owes_one_mouse_up(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.handle_mouse("drag", 80, 0)

        self.assertTrue(self.ink.end())
        self.assertEqual(1, len(self.finished))
        self.assertTrue(self.ink.needs_tap())
        # Still dragging after release: the app never saw the down.
        self.assertEqual((True, True), self.ink.handle_mouse("drag", 90, 0))
        self.assertEqual((True, False), self.ink.handle_mouse("up", 90, 0))
        self.assertFalse(self.ink.needs_tap())
        self.assertEqual((False, False), self.ink.handle_mouse("down", 5, 5))

    def test_a_new_click_cancels_an_owed_mouse_up(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.end()

        self.assertEqual((False, False), self.ink.handle_mouse("down", 5, 5))
        self.assertFalse(self.ink.needs_tap())

    def test_an_owed_mouse_up_expires(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.end()

        self.assertFalse(self.ink.expire_pending_up())
        self.clock.now += 10
        self.assertTrue(self.ink.expire_pending_up())
        self.assertFalse(self.ink.needs_tap())

    def test_a_press_owed_from_the_last_session_stays_ours(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.end()
        # The next dictation starts before that button comes up.
        self.ink.begin()
        self.assertEqual((True, True), self.ink.handle_mouse("drag", 5, 0))
        self.assertEqual((True, True), self.ink.handle_mouse("up", 5, 0))
        self.assertEqual([], self.ink.take_strokes())

    def test_a_tap_timeout_gives_up_the_button(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.handle_mouse("drag", 40, 0)
        self.ink.forget_button()

        self.assertEqual(1, len(self.finished))
        # The app may have seen a fresh mouse-down while the tap was off.
        self.assertEqual((False, True), self.ink.handle_mouse("up", 50, 0))
        self.assertTrue(self.ink.is_active())

    def test_resume_keeps_the_marks(self):
        self.ink.begin()
        self.drag((0, 0), (100, 0))
        self.ink.end()

        self.assertTrue(self.ink.resume())
        self.assertFalse(self.ink.resume())
        self.drag((0, 50), (100, 50))
        self.assertEqual([1, 2], [s.number for s in self.ink.take_strokes()])

    def test_release_with_no_button_down_lets_the_tap_go(self):
        self.ink.begin()
        self.drag((0, 0), (100, 0))
        self.assertFalse(self.ink.end())
        self.assertFalse(self.ink.needs_tap())

    def test_reset_stops_all_swallowing(self):
        self.ink.begin()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.reset()
        self.assertFalse(self.ink.needs_tap())
        self.assertEqual((False, False), self.ink.handle_mouse("up", 0, 0))

    def test_snapshot_shows_the_stroke_in_progress(self):
        self.ink.begin()
        version, finished, current = self.ink.snapshot()
        self.ink.handle_mouse("down", 0, 0)
        self.ink.handle_mouse("drag", 10, 0)
        new_version, finished, current = self.ink.snapshot()
        self.assertGreater(new_version, version)
        self.assertEqual([], finished)
        self.assertEqual([(0, 0), (10, 0)], current)


class DrawingSessionTests(unittest.TestCase):
    """The module-level session glue, with the Quartz tap faked out."""

    def setUp(self):
        self.module = load_module()
        self.tap_states = []
        self.module._mouse_tap = object()
        self.module._set_mouse_tap = self.tap_states.append
        self.module.set_drawing_enabled(True)
        self.tap_states.clear()

    def press(self):
        self.module._hotkeys.handle_event("key_down", 111)

    def release(self):
        self.module._hotkeys.handle_event("key_up", 111)

    def test_session_starts_only_while_the_key_is_down(self):
        self.assertFalse(self.module.begin_drawing_session())
        self.press()
        self.assertTrue(self.module.begin_drawing_session())
        self.assertEqual([True], self.tap_states)

    def test_disabled_setting_never_starts_a_session(self):
        self.module.set_drawing_enabled(False)
        self.press()
        self.assertFalse(self.module.begin_drawing_session())

    def test_end_takes_marks_and_turns_the_tap_off(self):
        self.press()
        self.module.begin_drawing_session()
        self.module._ink.handle_mouse("down", 10, 10)
        self.module._ink.handle_mouse("up", 10, 10)
        self.release()

        strokes = self.module.end_drawing_session()
        self.assertEqual(1, len(strokes))
        self.assertEqual(False, self.tap_states[-1])

    def test_watchdog_releases_a_session_left_behind_by_a_reset(self):
        self.press()
        self.module.begin_drawing_session()
        self.module._hotkeys.reset()

        self.module.drawing_watchdog()
        self.assertFalse(self.module._ink.needs_tap())
        self.assertEqual(False, self.tap_states[-1])

    def test_a_quick_release_and_press_brings_drawing_back(self):
        self.press()
        self.module.begin_drawing_session()
        self.module._ink.handle_mouse("down", 10, 10)
        self.module._ink.handle_mouse("up", 10, 10)
        # The tap thread sees the key go up and ends drawing at once...
        self.release()
        self.module._release_drawing()
        self.module.keep_drawing_session()
        self.assertFalse(self.module._ink.is_active())
        # ...then it's pressed again before the worker's next poll.
        self.press()
        self.module.keep_drawing_session()

        self.assertTrue(self.module._ink.is_active())
        self.assertEqual(True, self.tap_states[-1])
        self.assertEqual(1, len(self.module.end_drawing_session()))

    def test_wake_resets_drawing(self):
        self.press()
        self.module.begin_drawing_session()
        self.module._ink.handle_mouse("down", 10, 10)
        self.module._note_system_wake(None)
        self.assertFalse(self.module._ink.needs_tap())
        self.assertEqual(False, self.tap_states[-1])


class FakeDataPasteboard(FakePasteboard):
    def setData_forType_(self, data, pasteboard_type):
        self.change_count += 1
        self.items = [FakePasteboardItem({pasteboard_type: data})]
        return True


class LazyItem(FakePasteboardItem):
    def __init__(self, payload, pasteboard_type, on_read):
        super().__init__()
        self.payload = payload
        self.pasteboard_type = pasteboard_type
        self.on_read = on_read

    def read(self):
        self.values[self.pasteboard_type] = self.payload
        self.on_read()


def leave(pasteboard, payload, pasteboard_type, offered):
    if pasteboard.changeCount() == offered:
        pasteboard.clearContents()
        pasteboard.setData_forType_(payload, pasteboard_type)


class PasteSequenceTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.pasteboard = FakeDataPasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )
        self.pasted = []
        self.sleeps = []

    def target_reads(self):
        item = self.pasteboard.items[0]
        item.read()
        self.pasted.append((item.pasteboard_type, item.payload))

    def paste(self, items, post_paste=None, landed=None):
        return self.module._paste_sequence_via_pasteboard(
            self.pasteboard,
            items,
            post_paste or self.target_reads,
            landed=landed,
            make_item=LazyItem,
            item_class=FakePasteboardItem,
            leave_on_clipboard=leave,
            timeout=0.05,
            gap=0.35,
            sleep=self.sleeps.append,
        )

    def test_text_then_each_image_in_order_then_clipboard_restored(self):
        count, ok = self.paste([
            ("see [1] and [2]", "public.utf8-plain-text"),
            (b"png one", "public.png"),
            (b"png two", "public.png"),
        ], landed=lambda: True)

        self.assertEqual((3, True), (count, ok))
        self.assertEqual(
            [
                ("public.utf8-plain-text", "see [1] and [2]"),
                ("public.png", b"png one"),
                ("public.png", b"png two"),
            ],
            self.pasted,
        )
        self.assertEqual(
            [{"public.utf8-plain-text": b"old clipboard"}],
            [item.values for item in self.pasteboard.items],
        )
        # A gap before each image and after the last one.
        self.assertEqual(3, self.sleeps.count(0.35))

    def test_a_copy_part_way_through_stops_the_sequence_and_is_kept(self):
        def target_reads_then_user_copies():
            self.target_reads()
            self.pasteboard.setString_forType_("user copy", "public.utf8-plain-text")

        count, ok = self.paste([
            ("words", "public.utf8-plain-text"),
            (b"png one", "public.png"),
        ], post_paste=target_reads_then_user_copies)

        self.assertEqual((1, False), (count, ok))
        self.assertEqual([("public.utf8-plain-text", "words")], self.pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": "user copy"}],
            [item.values for item in self.pasteboard.items],
        )

    def test_images_only(self):
        count, ok = self.paste([(b"png one", "public.png")])
        self.assertEqual((1, True), (count, ok))
        self.assertEqual([("public.png", b"png one")], self.pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": b"old clipboard"}],
            [item.values for item in self.pasteboard.items],
        )

    def test_text_that_found_no_text_box_stops_before_the_images(self):
        count, ok = self.paste([
            ("words", "public.utf8-plain-text"),
            (b"png one", "public.png"),
        ], landed=lambda: False)

        self.assertEqual((1, False), (count, ok))
        self.assertEqual([("public.utf8-plain-text", "words")], self.pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": "words"}],
            [item.values for item in self.pasteboard.items],
        )

    def test_an_image_the_target_never_reads_is_left_on_the_clipboard(self):
        calls = []

        def post_paste():
            calls.append(1)
            if len(calls) == 1:
                self.target_reads()

        count, ok = self.paste([
            ("words", "public.utf8-plain-text"),
            (b"png one", "public.png"),
            (b"png two", "public.png"),
        ], post_paste=post_paste, landed=lambda: True)

        self.assertEqual((1, False), (count, ok))
        self.assertEqual(2, len(calls))
        self.assertEqual(
            [{"public.png": b"png one"}],
            [item.values for item in self.pasteboard.items],
        )


if __name__ == "__main__":
    unittest.main()
