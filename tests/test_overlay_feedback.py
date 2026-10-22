"""Exercise the real finalizers and UI timers without starting a worker."""
import ast
import ctypes
import ctypes.wintypes
import math
from pathlib import Path
import queue
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from overlay_feedback import checkmark_points


def worker_namespace():
    tree = ast.parse((ROOT / "voice-type.py").read_text(encoding="utf-8"))
    names = {"paste_text", "_paste_with_feedback", "_finish_one_shot",
             "_finish_precompute", "_finish_stabilized", "Overlay"}
    selected = ast.Module(body=[node for node in tree.body
                               if isinstance(node, (ast.FunctionDef, ast.ClassDef))
                               and node.name in names], type_ignores=[])
    ns = dict(np=np, time=mock.Mock(wraps=time), threading=threading,
              checkmark_points=checkmark_points,
              queue=queue, math=math, sys=sys, platform=mock.Mock(),
              _injection_lock=threading.Lock(), log=mock.Mock(),
              transcribe=mock.Mock(return_value="two words"),
              _maybe_format_final_text=lambda text, mode: text,
              _remember_transcription=mock.Mock(), _update_recording=mock.Mock(),
              _wrap_preview=lambda text: text, SAMPLE_RATE=16000, PRECOMP_OVERLAP=1,
              _COL_REC="#FF453A", _COL_PROC="#FF9F0A", _COL_DONE="#30D158",
              _N_BARS=7, _BAR_MIN_H=3, _BAR_MAX_H=20, _CANVAS_H=28,
              _BAR_W=4, _BAR_GAP=3)
    ns["time"].sleep = mock.Mock()
    exec(compile(selected, "voice-type.py", "exec"), ns)
    return ns


class FinalizationFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.ns = worker_namespace()
        self.overlay = mock.Mock()
        self.tray = mock.Mock()

    def test_paste_propagates_mac_failure_and_accepts_windows_none(self):
        for result, expected in ((False, False), (True, True), (None, True)):
            with self.subTest(result=result):
                self.ns["platform"].inject_text.return_value = result
                self.assertIs(self.ns["paste_text"]("two words"), expected)
        self.ns["platform"].inject_text.reset_mock()
        self.assertFalse(self.ns["paste_text"]("  "))
        self.ns["platform"].inject_text.assert_not_called()

    def finish(self, mode):
        args = (np.zeros(100), self.overlay, self.tray, time.perf_counter())
        if mode == "precompute":
            self.ns["_finish_precompute"](*args, "two words", 100)
        else:
            self.ns["_finish_one_shot"](*args, mode)

    def test_completion_waits_for_injection_and_handles_failure_in_all_paste_modes(self):
        for mode in ("hybrid", "final_only", "precompute"):
            for pasted in (True, False):
                with self.subTest(mode=mode, pasted=pasted):
                    self.overlay.reset_mock()
                    def inject(text, log):
                        self.overlay.hide.assert_not_called()
                        self.overlay.show_done.assert_not_called()
                        self.overlay.show_paste_failed.assert_not_called()
                        return pasted
                    self.ns["platform"].inject_text.side_effect = inject
                    self.finish(mode)
                    if pasted:
                        self.overlay.show_done.assert_called_once_with(2)
                        self.overlay.show_paste_failed.assert_not_called()
                    else:
                        self.overlay.show_paste_failed.assert_called_once_with()
                        self.overlay.show_done.assert_not_called()
                    self.overlay.hide.assert_not_called()

    def test_paste_error_hides_processing_pill(self):
        self.ns["platform"].inject_text.side_effect = RuntimeError("pasteboard")
        with self.assertRaises(RuntimeError):
            self.finish("final_only")
        self.overlay.hide.assert_called_once_with()
        self.overlay.show_done.assert_not_called()
        self.overlay.show_paste_failed.assert_not_called()

    def test_empty_transcript_hides_without_success(self):
        self.ns["transcribe"].return_value = ""
        self.finish("final_only")
        self.overlay.hide.assert_called_once_with()
        self.overlay.show_done.assert_not_called()
        self.ns["platform"].inject_text.assert_not_called()

    def test_stabilized_completes_after_tail_correction(self):
        def transcribe(audio, on_segment):
            on_segment("two word")
            return "two words"
        self.ns["transcribe"].side_effect = transcribe
        events = mock.Mock()
        events.attach_mock(self.ns["platform"].inject_text, "inject")
        events.attach_mock(self.overlay.show_done, "done")
        self.ns["_finish_stabilized"](np.zeros(100), self.overlay, self.tray, 0)
        self.assertEqual([mock.call.inject("two word", self.ns["log"]),
                          mock.call.inject("s", self.ns["log"]),
                          mock.call.done(2)], events.mock_calls)
        self.overlay.hide.assert_not_called()

    def test_stabilized_failed_segment_hides_instead_of_ticking(self):
        def transcribe(audio, on_segment):
            on_segment("two words")
            return "two words"
        self.ns["transcribe"].side_effect = transcribe
        self.ns["platform"].inject_text.return_value = False
        self.ns["_finish_stabilized"](np.zeros(100), self.overlay, self.tray, 0)
        self.overlay.show_done.assert_not_called()
        self.overlay.hide.assert_called_once_with()


class FakeRoot:
    def __init__(self):
        self.pending = {}
        self.serial = 0
        self.alpha = 1.0

    def after(self, ms, callback):
        self.serial += 1
        self.pending[self.serial] = (ms, callback)
        return self.serial

    def after_cancel(self, ident):
        self.pending.pop(ident, None)

    def attributes(self, name, value):
        if name == "-alpha":
            self.alpha = value

    def withdraw(self):
        pass

    def fire(self, ident):
        self.pending.pop(ident)[1]()


class OverlayFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.ns = worker_namespace()
        self.overlay = self.ns["Overlay"].__new__(self.ns["Overlay"])
        self.overlay._root = FakeRoot()
        self.overlay._cmd_queue = queue.Queue()
        self.overlay._state = "processing"
        self.overlay._visible = True
        self.overlay._feedback_after = None
        self.overlay._feedback_started = 0
        self.overlay._monitor = (0, 0, 1920, 1080)
        self.overlay._native_surface = mock.Mock()
        self.overlay._is_native_surface = True
        self.overlay._pending_settings_payload = None
        self.overlay._position = mock.Mock()
        self.overlay._reposition = mock.Mock()
        self.ns["platform"].reduce_motion_enabled.return_value = False

    def test_success_holds_then_fades_and_hides(self):
        self.overlay.show_done(1)
        self.overlay._poll()
        self.overlay._native_surface.set_state.assert_called_with("done", "1 word")
        timer = self.overlay._feedback_after
        self.assertEqual(220, self.overlay._root.pending[timer][0])
        self.overlay._root.fire(timer)
        self.assertTrue(self.overlay._visible)
        self.ns["time"].monotonic.return_value = self.overlay._fade_started + 0.14
        self.overlay._root.fire(self.overlay._feedback_after)
        self.assertFalse(self.overlay._visible)

    def test_new_recording_cancels_hold_and_restores_opacity(self):
        self.overlay.show_done(42)
        self.overlay._poll()
        old_timer = self.overlay._feedback_after
        self.overlay.show_rec()
        self.overlay._poll()
        self.assertNotIn(old_timer, self.overlay._root.pending)
        self.assertEqual("rec", self.overlay._state)
        self.overlay._native_surface.set_alpha.assert_called_with(1.0)
        self.assertIsNone(self.overlay._feedback_after)

    def test_new_recording_cancels_mid_fade(self):
        self.overlay.show_done(2)
        self.overlay._poll()
        self.overlay._root.fire(self.overlay._feedback_after)
        timer = self.overlay._feedback_after
        self.overlay.hide()  # queued immediately on key-down, before first audio
        self.overlay.show_rec()
        self.overlay._poll()
        self.assertNotIn(timer, self.overlay._root.pending)
        self.assertTrue(self.overlay._visible)
        self.assertEqual("rec", self.overlay._state)

    def test_reduced_motion_hides_after_hold_without_fade(self):
        self.ns["platform"].reduce_motion_enabled.return_value = True
        self.overlay.show_done(2)
        self.overlay._poll()
        self.overlay._native_surface.set_completion_progress.assert_called_with(1.0)
        self.overlay._root.fire(self.overlay._feedback_after)
        self.assertFalse(self.overlay._visible)
        self.assertIsNone(self.overlay._feedback_after)

    def test_failure_has_longer_hold_and_platform_shortcut(self):
        for os_name, shortcut in (("darwin", "⌘V"), ("win32", "Ctrl+V")):
            with self.subTest(platform=os_name), mock.patch.object(sys, "platform", os_name):
                self.overlay.show_paste_failed()
                self.overlay._poll()
                self.overlay._native_surface.set_state.assert_called_with(
                    "paste_failed", f"On your clipboard. {shortcut} to paste")
                self.assertEqual(1600, self.overlay._root.pending[self.overlay._feedback_after][0])
                self.overlay._root.fire(self.overlay._feedback_after)
                self.assertFalse(self.overlay._visible)

    def test_tk_completion_draws_tick_and_resets_for_next_recording(self):
        self.overlay._is_native_surface = False
        self.overlay._native_surface = None
        for name in ("_accent", "_dot", "_label", "_canvas", "_preview"):
            setattr(self.overlay, name, mock.Mock())
        self.overlay._bar_ids = list(range(7))
        self.overlay._check_id = 99
        self.overlay._has_open_or_pending_dialogs = lambda: False
        self.overlay.show_done(42)
        self.overlay._poll()
        self.overlay._label.configure.assert_called_with(text="42 words")
        self.overlay._accent.configure.assert_called_with(bg="#30D158")
        self.overlay._state = "done"
        self.overlay._bar_h = [3.0] * 7
        self.overlay._reduce_motion = True
        self.overlay._animate()
        self.overlay._canvas.coords.assert_any_call(99, 12.0, 12.0, 20.0, 20.0, 36.0, 4.0)
        self.overlay.show_rec()
        self.overlay._poll()
        self.overlay._canvas.itemconfigure.assert_any_call(99, state="hidden")


class NativeSurfaceFeedbackTests(unittest.TestCase):
    def setUp(self):
        tree = ast.parse((ROOT / "appkit_overlay.py").read_text(encoding="utf-8"))
        # Keep the real layout constants so width checks match the shipped pill.
        selected = ast.Module(body=[node for node in tree.body
                                   if (isinstance(node, ast.ClassDef)
                                       and node.name in ("_BarsView", "AppKitOverlaySurface"))
                                   or isinstance(node, ast.Assign)], type_ignores=[])
        self.ns = dict(NSView=object, NSBezierPath=mock.Mock(), NSColor=mock.Mock(),
                       NSMakeRect=lambda *args: args, checkmark_points=checkmark_points,
                       _BAR_W=4, _BAR_GAP=3)
        exec(compile(selected, "appkit_overlay.py", "exec"), self.ns)
        self.surface = self.ns["AppKitOverlaySurface"].__new__(self.ns["AppKitOverlaySurface"])
        for name in ("_label", "_preview", "_accent", "_dot", "_panel", "_layout"):
            setattr(self.surface, name, mock.Mock())
        bars = self.ns["_BarsView"]()
        bars._bar_heights = [20.0] * 7
        bars.setNeedsDisplay_ = mock.Mock()
        bars.bounds = mock.Mock(return_value=SimpleNamespace(size=SimpleNamespace(height=24)))
        self.surface._bars = bars

    def test_native_success_uses_green_count_and_draws_check_in_place_of_bars(self):
        self.surface.set_state("done", "42 words")
        self.surface._label.setStringValue_.assert_called_with("42 words")
        self.surface._preview.setStringValue_.assert_called_with("")
        self.assertEqual([3.0] * 7, self.surface._bars._bar_heights)
        self.ns["NSColor"].colorWithCalibratedRed_green_blue_alpha_.assert_called_with(
            48 / 255, 209 / 255, 88 / 255, 1.0)
        self.surface.set_completion_progress(1.0)
        self.surface._bars.drawRect_(None)
        path = self.ns["NSBezierPath"].bezierPath.return_value
        path.moveToPoint_.assert_called_with((12.0, 12.0))
        self.assertEqual([mock.call((20.0, 20.0)), mock.call((36.0, 4.0))], path.lineToPoint_.call_args_list)
        path.stroke.assert_called_once_with()
        self.ns["NSBezierPath"].bezierPathWithRoundedRect_xRadius_yRadius_.assert_not_called()

    def test_recording_label_keeps_its_old_width_and_only_feedback_grows(self):
        self.surface._layout = self.ns["AppKitOverlaySurface"]._layout.__get__(self.surface)
        for name in ("_content", "_bars"):
            setattr(self.surface, name, mock.Mock())
        widths = {}
        for state in ("rec", "processing", "done", "paste_failed"):
            self.surface._state = state
            self.surface._layout()
            widths[state] = self.surface._label.setFrame_.call_args[0][0][2]
            self.surface._panel.setContentSize_.assert_called_with((220, self.ns["_PANEL_HEIGHT"]))
        self.assertEqual({"rec": 50, "processing": 50, "done": 124, "paste_failed": 124}, widths)

    def test_native_recording_resets_check_and_failure_keeps_full_hint(self):
        self.surface.set_state("done", "2 words")
        self.surface.set_state("rec", "next recording")
        self.assertIsNone(self.surface._bars._check_progress)
        self.surface._bars.drawRect_(None)
        self.assertEqual(7, self.ns["NSBezierPath"].bezierPathWithRoundedRect_xRadius_yRadius_.call_count)
        hint = "On your clipboard. ⌘V to paste"
        self.surface.set_state("paste_failed", hint)
        self.surface._preview.setStringValue_.assert_called_with(hint)
        self.assertIsNone(self.surface._bars._check_progress)
        self.assertEqual([3.0] * 7, self.surface._bars._bar_heights)


class CheckmarkTests(unittest.TestCase):
    def test_draws_short_stroke_before_long_stroke_and_clamps(self):
        self.assertEqual((12, 12, 12, 12, 12, 12), checkmark_points(-1))
        self.assertEqual((12, 12, 20, 20, 20, 20), checkmark_points(1 / 3))
        self.assertEqual((12, 12, 20, 20, 36, 4), checkmark_points(2))


class MotionPreferenceTests(unittest.TestCase):
    def test_windows_client_area_animation_setting_and_query_failure(self):
        tree = ast.parse((ROOT / "platform_win.py").read_text(encoding="utf-8"))
        selected = ast.Module(body=[node for node in tree.body
                                   if isinstance(node, ast.FunctionDef)
                                   and node.name == "reduce_motion_enabled"], type_ignores=[])
        user32 = mock.Mock()
        ns = dict(ctypes=ctypes, _user32=user32)
        exec(compile(selected, "platform_win.py", "exec"), ns)
        for animation_enabled in (True, False):
            def query(action, param, output, flags):
                self.assertEqual(0x1042, action)
                output._obj.value = animation_enabled
                return 1
            user32.SystemParametersInfoW.side_effect = query
            self.assertEqual(not animation_enabled, ns["reduce_motion_enabled"]())
        user32.SystemParametersInfoW.side_effect = None
        user32.SystemParametersInfoW.return_value = 0
        self.assertTrue(ns["reduce_motion_enabled"]())

    def test_macos_uses_accessibility_reduce_motion_preference(self):
        import platform_mac
        workspace = mock.Mock()
        appkit = SimpleNamespace(NSWorkspace=workspace)
        with mock.patch.dict(sys.modules, AppKit=appkit):
            for enabled in (True, False):
                workspace.sharedWorkspace.return_value.accessibilityDisplayShouldReduceMotion.return_value = enabled
                self.assertIs(enabled, platform_mac.reduce_motion_enabled())


if __name__ == "__main__":
    unittest.main()
