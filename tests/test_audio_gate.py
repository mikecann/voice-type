import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "audio_gate.py"


def load_module():
    spec = importlib.util.spec_from_file_location("audio_gate", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class AudioGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_skips_short_near_silent_audio(self):
        self.assertTrue(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.4,
                rms=0.001,
                peak=0.01,
            )
        )

    def test_detects_long_digital_flatline(self):
        self.assertTrue(
            self.module.is_flatline_audio_capture(
                duration_sec=4.2,
                rms=0.0,
                peak=0.0,
            )
        )

    def test_short_empty_capture_is_not_treated_as_broken_stream(self):
        self.assertFalse(
            self.module.is_flatline_audio_capture(
                duration_sec=0.05,
                rms=0.0,
                peak=0.0,
            )
        )

    def test_long_quiet_audio_is_not_a_digital_flatline(self):
        self.assertFalse(
            self.module.is_flatline_audio_capture(
                duration_sec=4.2,
                rms=0.001,
                peak=0.01,
            )
        )

    def test_flatline_messages_explain_the_recovery(self):
        self.assertEqual(
            "No microphone audio\nRelease to restart",
            self.module.FLATLINE_RECORDING_MESSAGE,
        )
        self.assertEqual(
            "No microphone audio\nRestarting Voice Type...",
            self.module.FLATLINE_RECOVERY_MESSAGE,
        )

    def test_keeps_long_quiet_audio(self):
        self.assertFalse(
            self.module.should_skip_short_low_level_audio(
                duration_sec=1.2,
                rms=0.001,
                peak=0.01,
            )
        )

    def test_keeps_short_quietly_spoken_phrase(self):
        # Levels of a real "same here" that the old 0.03 peak limit dropped.
        self.assertFalse(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.69,
                rms=0.0036,
                peak=0.0249,
            )
        )

    def test_skips_short_room_noise(self):
        self.assertTrue(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.59,
                rms=0.0006,
                peak=0.0079,
            )
        )

    def test_skips_quiet_accidental_tap(self):
        # A 0.14s tap that Whisper transcribed as "Thank you."
        self.assertTrue(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.14,
                rms=0.0036,
                peak=0.0189,
            )
        )

    def test_keeps_short_audio_with_clear_peak(self):
        self.assertFalse(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.4,
                rms=0.001,
                peak=0.2,
            )
        )



class RepetitionLoopGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = staticmethod(load_module().guard_repetition_loops)

    def test_drops_a_clip_that_is_only_a_loop(self):
        # Both of these were pasted for real in October 2026.
        self.assertEqual("", self.guard(" ".join(["making"] * 300), duration_sec=1.4))
        self.assertEqual("", self.guard("Call us " * 100 + "Call", duration_sec=0.4))
        self.assertEqual("", self.guard("Flare. Flare. Flare. Flare. Flare. Flare. Flare. Flare.", duration_sec=2.0))

    def test_collapses_a_loop_after_real_words(self):
        text = "I think we should ship it today. " + "the " * 40
        self.assertEqual(
            "I think we should ship it today. the",
            self.guard(text.strip(), duration_sec=6.0),
        )

    def test_keeps_a_few_repeats_at_a_normal_pace(self):
        self.assertEqual("No, no, no, no.", self.guard("No, no, no, no.", duration_sec=1.5))
        self.assertEqual(
            "Okay, okay, okay, okay, let's go.",
            self.guard("Okay, okay, okay, okay, let's go.", duration_sec=2.5),
        )

    def test_four_repeats_count_when_they_came_out_too_fast(self):
        self.assertEqual("", self.guard("Call us Call us Call us Call us", duration_sec=0.5))

    def test_leaves_ordinary_text_alone(self):
        for text in ["", "Merge it.", "Can you take a look at the PR, please?"]:
            self.assertEqual(text, self.guard(text, duration_sec=2.0))


if __name__ == "__main__":
    unittest.main()
