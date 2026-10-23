"""Run the real finalizers with screen marks, against a fake platform."""
import ast
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import screen_marks
from mark_capture import DictationMarks


def worker_namespace(transcript="This button is broken and this one too"):
    tree = ast.parse((ROOT / "voice-type.py").read_text(encoding="utf-8"))
    names = {
        "paste_text", "_paste_with_feedback", "_finish_one_shot",
        "_finish_precompute", "_finish_stabilized", "_place_mark_markers",
        "_paste_marks_with_feedback", "_finish_marks_only",
    }
    selected = ast.Module(body=[node for node in tree.body
                               if isinstance(node, ast.FunctionDef)
                               and node.name in names], type_ignores=[])
    ns = dict(
        np=np, time=mock.Mock(wraps=time), threading=threading, sys=sys,
        platform=mock.Mock(), _injection_lock=threading.Lock(), log=mock.Mock(),
        transcribe=mock.Mock(return_value=transcript),
        _maybe_format_final_text=lambda text, mode: text,
        _remember_transcription=mock.Mock(), _update_recording=mock.Mock(),
        _wrap_preview=lambda text: text, SAMPLE_RATE=16000, PRECOMP_OVERLAP=1,
        merge_overlapping_transcripts=lambda a, b: f"{a} {b}",
        timings_from_segments=screen_marks.timings_from_segments,
        spoken_word_counts=screen_marks.spoken_word_counts,
        insert_markers=screen_marks.insert_markers,
        append_markers=screen_marks.append_markers,
        marker_text=screen_marks.marker_text,
    )
    ns["time"].sleep = mock.Mock()
    exec(compile(selected, "voice-type.py", "exec"), ns)
    ns["platform"].inject_text.return_value = True
    ns["platform"].inject_text_and_images.return_value = True
    return ns


def word_segments():
    words = "This button is broken and this one too".split()
    timed = [
        SimpleNamespace(start=i * 0.5, end=i * 0.5 + 0.4, word=f" {w}")
        for i, w in enumerate(words)
    ]
    return [SimpleNamespace(text=" ".join(words), start=0.0, end=4.0, words=timed)]


class FakeSession:
    def __init__(self, shots, permission_missing=False):
        self.shots = shots
        self.permission_missing = permission_missing

    def wait(self, timeout):
        return self.shots


class DrawFinalizeTests(unittest.TestCase):
    def setUp(self):
        self.ns = worker_namespace()
        self.overlay = mock.Mock()
        self.tray = mock.Mock()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = []
        for n in (1, 2):
            path = Path(self.tmp.name) / f"{n}.png"
            path.write_bytes(f"png {n}".encode())
            self.paths.append((n, str(path)))

    def marks(self, shots=None, permission_missing=False):
        # Mark 1 finished at 0.7s of audio (during "button"), mark 2 at 2.7s
        # (during "this"). Audio began 10s into the monotonic clock.
        strokes = [
            screen_marks.Stroke([(0, 0), (100, 0)], 10.2, 10.7, number=1),
            screen_marks.Stroke([(0, 0)], 12.5, 12.7, number=2),
        ]
        return DictationMarks(
            strokes,
            FakeSession(self.paths if shots is None else shots, permission_missing),
            audio_origin=10.0,
        )

    def transcribe_with_timings(self, *args, timings=None, **kwargs):
        timings.extend(word_segments())
        return "This button is broken and this one too"

    def finish(self, marks=None, mode="final_only"):
        self.ns["_finish_one_shot"](np.zeros(100), self.overlay, self.tray, time.perf_counter(), mode, marks)

    def test_no_marks_takes_exactly_the_old_path(self):
        self.finish(marks=None)

        self.ns["transcribe"].assert_called_once()
        self.assertEqual({"on_segment": None}, self.ns["transcribe"].call_args.kwargs)
        self.ns["platform"].inject_text.assert_called_once()
        self.assertEqual(
            "This button is broken and this one too",
            self.ns["platform"].inject_text.call_args.args[0],
        )
        self.ns["platform"].inject_text_and_images.assert_not_called()
        self.overlay.show_done.assert_called_once_with(8)

    def test_marks_put_markers_in_the_text_and_paste_images_in_order(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.finish(self.marks())

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual("This button [1] is broken and this [2] one too", text)
        self.assertEqual([b"png 1", b"png 2"], images)
        self.ns["platform"].inject_text.assert_not_called()
        self.overlay.show_done.assert_called_once_with(10, 2)
        self.ns["_update_recording"].assert_any_call(screenshots=[p for _n, p in self.paths])
        self.ns["_remember_transcription"].assert_called_once_with(text, "final_only")

    def test_markers_survive_the_formatter(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.ns["_maybe_format_final_text"] = lambda text, mode: "This button is broken, and this one too."
        self.finish(self.marks())

        text = self.ns["platform"].inject_text_and_images.call_args.args[0]
        self.assertEqual("This button [1] is broken, and this [2] one too.", text)

    def test_marks_sharing_a_window_get_both_markers_and_one_image(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        shared = self.paths[0][1]
        self.finish(self.marks(shots=[(1, shared), (2, shared)]))

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual("This button [1] is broken and this [2] one too", text)
        self.assertEqual([b"png 1"], images)
        self.overlay.show_done.assert_called_once_with(10, 1)
        self.ns["_update_recording"].assert_any_call(screenshots=[shared])

    def test_a_failed_capture_drops_its_marker(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.finish(self.marks(shots=[self.paths[1]]))

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual("This button is broken and this [2] one too", text)
        self.assertEqual([b"png 2"], images)

    def test_marks_but_no_words_pastes_just_the_images(self):
        self.ns["transcribe"].return_value = ""
        self.finish(self.marks())

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual("", text)
        self.assertEqual([b"png 1", b"png 2"], images)
        self.overlay.show_done.assert_called_once_with(0, 2)

    def test_without_permission_the_text_is_still_pasted_with_a_hint(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.finish(self.marks(shots=[], permission_missing=True))

        self.ns["platform"].inject_text.assert_called_once()
        self.assertEqual(
            "This button is broken and this one too",
            self.ns["platform"].inject_text.call_args.args[0],
        )
        self.ns["platform"].inject_text_and_images.assert_not_called()
        names = [c[0] for c in self.overlay.method_calls]
        self.assertLess(names.index("show_done"), names.index("show_screen_recording_hint"))

    def test_a_failed_image_paste_points_at_the_clipboard(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.ns["platform"].inject_text_and_images.return_value = False
        self.finish(self.marks())
        self.overlay.show_paste_failed.assert_called_once_with()

    def test_precompute_with_marks_runs_one_timed_full_pass(self):
        self.ns["transcribe"].side_effect = self.transcribe_with_timings
        self.ns["_finish_precompute"](
            np.zeros(32000), self.overlay, self.tray, time.perf_counter(),
            "This button", 8000, self.marks(),
        )
        self.ns["transcribe"].assert_called_once()
        text = self.ns["platform"].inject_text_and_images.call_args.args[0]
        self.assertIn("[1]", text)

    def test_stabilized_appends_markers_after_the_typed_words(self):
        self.ns["transcribe"].return_value = "Look here"
        self.ns["_finish_stabilized"](np.zeros(100), self.overlay, self.tray, 0, self.marks())

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual(" [1] [2]", text)
        self.assertEqual([b"png 1", b"png 2"], images)

    def test_stabilized_with_a_shared_window_pastes_one_image(self):
        self.ns["transcribe"].return_value = "Look here"
        shared = self.paths[1][1]
        self.ns["_finish_stabilized"](
            np.zeros(100), self.overlay, self.tray, 0,
            self.marks(shots=[(1, shared), (2, shared)]),
        )

        text, images, _log = self.ns["platform"].inject_text_and_images.call_args.args
        self.assertEqual(" [1] [2]", text)
        self.assertEqual([b"png 2"], images)
        self.ns["_remember_transcription"].assert_called_once_with("Look here [1] [2]", "stabilized")


if __name__ == "__main__":
    unittest.main()
