import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "mic_stream.py"


def load_module():
    spec = importlib.util.spec_from_file_location("mic_stream", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeStream:
    def __init__(self, name, events, *, fail_start=False):
        self.name = name
        self.events = events
        self.fail_start = fail_start

    def start(self):
        self.events.append(("start", self.name))
        if self.fail_start:
            raise RuntimeError("device gone")

    def stop(self):
        self.events.append(("stop", self.name))

    def close(self):
        self.events.append(("close", self.name))


class Harness:
    def __init__(self, module, *, prepare_ahead=True, reusable=True):
        self.events = []
        self.opened = 0
        self.reusable = reusable
        self.fail_next_start = False
        self.stop_times_out = False
        self.mic = module.MicStream(
            open_stream=self._open,
            refresh_devices=lambda: self.events.append(("refresh",)),
            run_bounded=self._run_bounded,
            prepare_ahead=prepare_ahead,
        )
        self.module = module

    def _open(self):
        self.opened += 1
        name = f"s{self.opened}"
        self.events.append(("open", name))
        stream = FakeStream(name, self.events, fail_start=self.fail_next_start)
        self.fail_next_start = False
        return self.module.OpenedStream(stream, "Yeti", reusable=self.reusable)

    def _run_bounded(self, fn):
        if self.stop_times_out:
            return False
        fn()
        return True


class PreparedMicStreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_prepare_opens_without_starting(self):
        h = Harness(self.module)

        h.mic.prepare()

        self.assertEqual(h.events, [("open", "s1")])

    def test_start_reuses_the_prepared_stream(self):
        h = Harness(self.module)
        h.mic.prepare()

        reused = h.mic.start()

        self.assertTrue(reused)
        self.assertEqual(h.events, [("open", "s1"), ("start", "s1")])

    def test_stop_keeps_the_stream_for_the_next_recording(self):
        h = Harness(self.module)
        h.mic.prepare()
        h.mic.start()

        h.mic.stop()
        h.mic.prepare()
        h.mic.start()

        self.assertEqual(h.opened, 1)
        self.assertEqual(h.events[-2:], [("stop", "s1"), ("start", "s1")])

    def test_start_without_prepare_opens_on_demand(self):
        h = Harness(self.module)

        reused = h.mic.start()

        self.assertFalse(reused)
        self.assertEqual(h.events, [("open", "s1"), ("start", "s1")])

    def test_invalidate_reopens_on_next_prepare(self):
        h = Harness(self.module)
        h.mic.prepare()

        h.mic.invalidate()
        h.mic.prepare()

        self.assertEqual(
            h.events,
            [("open", "s1"), ("stop", "s1"), ("close", "s1"), ("open", "s2")],
        )

    def test_callback_error_reopens_on_next_start(self):
        h = Harness(self.module)
        h.mic.prepare()
        h.mic.start()
        h.mic.note_error()
        h.mic.stop()

        reused = h.mic.start()

        self.assertFalse(reused)
        self.assertEqual(h.opened, 2)

    def test_stream_on_a_fallback_device_is_not_reused(self):
        # The system default or a fallback mic can change between recordings,
        # so it has to be resolved again on key-down like before.
        h = Harness(self.module, reusable=False)
        h.mic.prepare()
        self.assertFalse(h.mic.start())
        h.mic.stop()

        h.mic.prepare()
        self.assertFalse(h.mic.start())

        # prepare() doesn't keep opening streams that key-down replaces.
        self.assertEqual(h.opened, 3)

    def test_prepare_does_not_touch_a_running_recording(self):
        h = Harness(self.module)
        h.mic.prepare()
        h.mic.start()
        h.mic.invalidate()

        h.mic.prepare()

        self.assertEqual(h.opened, 1)
        self.assertTrue(h.mic.is_running)

    def test_failed_start_on_prepared_stream_retries_with_a_fresh_one(self):
        h = Harness(self.module)
        h.fail_next_start = True
        h.mic.prepare()

        reused = h.mic.start()

        self.assertFalse(reused)
        self.assertEqual(h.opened, 2)
        self.assertEqual(h.events[-1], ("start", "s2"))
        self.assertTrue(h.mic.is_running)

    def test_failed_start_on_fresh_stream_raises_and_closes_it(self):
        h = Harness(self.module)
        h.fail_next_start = True

        with self.assertRaises(RuntimeError):
            h.mic.start()

        self.assertFalse(h.mic.is_running)
        self.assertEqual(h.events[-1], ("close", "s1"))

    def test_timed_out_stop_drops_the_stream(self):
        h = Harness(self.module)
        h.mic.prepare()
        h.mic.start()
        h.stop_times_out = True

        h.mic.stop()

        self.assertFalse(h.mic.is_running)
        h.stop_times_out = False
        h.mic.start()
        self.assertEqual(h.opened, 2)

    def test_refresh_closes_the_prepared_stream_first(self):
        # PortAudio's terminate frees every open stream, so refreshing the
        # device list must never happen underneath one we still hold.
        h = Harness(self.module)
        h.mic.prepare()

        refreshed = h.mic.refresh_devices()

        self.assertTrue(refreshed)
        self.assertEqual(
            h.events,
            [("open", "s1"), ("stop", "s1"), ("close", "s1"), ("refresh",)],
        )

    def test_refresh_is_skipped_while_recording(self):
        h = Harness(self.module)
        h.mic.start()

        refreshed = h.mic.refresh_devices()

        self.assertFalse(refreshed)
        self.assertNotIn(("refresh",), h.events)

    def test_device_name_survives_stop(self):
        h = Harness(self.module)
        h.mic.start()
        h.mic.stop()

        self.assertEqual(h.mic.device_name, "Yeti")


class OnDemandMicStreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_prepare_does_nothing(self):
        h = Harness(self.module, prepare_ahead=False)

        h.mic.prepare()

        self.assertEqual(h.events, [])

    def test_opens_on_start_and_closes_on_stop(self):
        h = Harness(self.module, prepare_ahead=False)

        h.mic.start()
        h.mic.stop()
        h.mic.start()

        self.assertEqual(
            h.events,
            [
                ("open", "s1"), ("start", "s1"),
                ("stop", "s1"), ("close", "s1"),
                ("open", "s2"), ("start", "s2"),
            ],
        )

    def test_device_name_survives_close(self):
        h = Harness(self.module, prepare_ahead=False)
        h.mic.start()
        h.mic.stop()

        self.assertEqual(h.mic.device_name, "Yeti")


if __name__ == "__main__":
    unittest.main()
