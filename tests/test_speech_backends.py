import importlib.util
import pathlib
import sys
import threading
import time
import unittest
from types import SimpleNamespace
from unittest import mock


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "speech_backends.py"


def load_module():
    spec = importlib.util.spec_from_file_location("speech_backends", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SpeechBackendsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_resolve_mlx_repo_prefers_arm_macos(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="small.en",
            has_mlx=True,
        )
        self.assertEqual("mlx-community/whisper-small.en-mlx", repo)

    def test_resolve_mlx_repo_returns_none_without_mlx(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="small.en",
            has_mlx=False,
        )
        self.assertIsNone(repo)

    def test_resolve_mlx_repo_returns_none_for_non_macos(self):
        repo = self.module.resolve_mlx_repo(
            system="win32",
            machine="arm64",
            model_name="small.en",
            has_mlx=True,
        )
        self.assertIsNone(repo)

    def test_resolve_mlx_repo_returns_none_for_unmapped_model(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="parakeet-tdt-0.6b",
            has_mlx=True,
        )
        self.assertIsNone(repo)

    def test_default_stream_model_uses_accelerated_model_on_apple_silicon(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=False,
            system="darwin",
            machine="arm64",
            has_mlx=True,
        )
        self.assertEqual("large-v3-turbo", model_name)

    def test_default_stream_model_uses_fallback_without_gpu_backend(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=False,
            system="darwin",
            machine="x86_64",
            has_mlx=False,
        )
        self.assertEqual("tiny.en", model_name)

    def test_default_stream_model_uses_accelerated_model_with_cuda(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=True,
            system="win32",
            machine="amd64",
            has_mlx=False,
        )
        self.assertEqual("large-v3-turbo", model_name)

    def test_load_local_mlx_model_selects_turbo_repo_and_warms_model(self):
        warmed = []

        class FakeModel:
            def __init__(self, *, repo_id):
                self.repo_id = repo_id

            def warm(self):
                warmed.append(self.repo_id)

        model = self.module.load_local_mlx_model(
            model_name="large-v3-turbo",
            repo_resolver=lambda *, model_name: (
                self.module.MLX_REPOS_BY_MODEL[model_name]
            ),
            model_factory=FakeModel,
        )

        self.assertEqual(
            "mlx-community/whisper-large-v3-turbo",
            model.repo_id,
        )
        self.assertEqual(
            ["mlx-community/whisper-large-v3-turbo"],
            warmed,
        )

    def test_load_local_mlx_model_returns_none_when_mlx_is_unavailable(self):
        model = self.module.load_local_mlx_model(
            model_name="large-v3-turbo",
            repo_resolver=lambda *, model_name: None,
            model_factory=mock.Mock(side_effect=AssertionError("must not load")),
        )
        self.assertIsNone(model)

    def test_mlx_transcribe_releases_cached_working_memory(self):
        cleared = []
        fake_mlx_whisper = SimpleNamespace(
            transcribe=lambda *_args, **_kwargs: {
                "text": "hello",
                "language": "en",
            }
        )
        fake_mlx_core = SimpleNamespace(clear_cache=lambda: cleared.append(True))

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": fake_mlx_whisper,
                "mlx": SimpleNamespace(core=fake_mlx_core),
            },
        ):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            segments, _info = model.transcribe([0.0], language="en")

        self.assertEqual(["hello"], [segment.text for segment in segments])
        self.assertEqual([True], cleared)

    def test_mlx_transcribe_releases_cache_when_transcription_fails(self):
        cleared = []

        def fail_transcription(*_args, **_kwargs):
            raise RuntimeError("transcription failed")

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": SimpleNamespace(transcribe=fail_transcription),
                "mlx": SimpleNamespace(
                    core=SimpleNamespace(clear_cache=lambda: cleared.append(True))
                ),
            },
        ):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            with self.assertRaisesRegex(RuntimeError, "transcription failed"):
                model.transcribe([0.0], language="en")

        self.assertEqual([True], cleared)

    def test_mlx_transcription_and_cache_cleanup_are_serialized(self):
        active = 0
        max_active = 0
        active_lock = threading.Lock()

        def transcribe(*_args, **_kwargs):
            nonlocal active, max_active
            with active_lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.04)
            with active_lock:
                active -= 1
            return {"text": "hello", "language": "en"}

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": SimpleNamespace(transcribe=transcribe),
                "mlx": SimpleNamespace(core=SimpleNamespace(clear_cache=lambda: None)),
            },
        ):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            threads = [
                threading.Thread(target=model.transcribe, args=([0.0],))
                for _ in range(2)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=1)

        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(1, max_active)

    def test_different_mlx_models_share_the_process_wide_inference_lock(self):
        active = 0
        max_active = 0
        active_lock = threading.Lock()

        def transcribe(*_args, **_kwargs):
            nonlocal active, max_active
            with active_lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.04)
            with active_lock:
                active -= 1
            return {"text": "hello", "language": "en"}

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": SimpleNamespace(transcribe=transcribe),
                "mlx": SimpleNamespace(core=SimpleNamespace(clear_cache=lambda: None)),
            },
        ):
            preview_model = self.module.MlxWhisperModel(repo_id="test/tiny")
            final_model = self.module.MlxWhisperModel(repo_id="test/turbo")
            threads = [
                threading.Thread(target=preview_model.transcribe, args=([0.0],)),
                threading.Thread(target=final_model.transcribe, args=([0.0],)),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=1)

        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(1, max_active)


def _speech(seconds: float, *, quiet_from: float | None = None, quiet_to: float | None = None):
    import numpy as np

    rate = 16000
    audio = np.random.default_rng(0).uniform(-0.3, 0.3, int(seconds * rate)).astype(np.float32)
    if quiet_from is not None:
        audio[int(quiet_from * rate):int(quiet_to * rate)] = 0.0
    return audio


class VocabularyPromptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_prompt_lists_words_as_one_punctuated_sentence(self):
        prompt = self.module.build_vocabulary_prompt(["Convex", " Tailscale ", "", "Convex", "Sammy Cam"])
        self.assertEqual("Convex, Tailscale, Sammy Cam.", prompt)

    def test_no_words_means_no_prompt(self):
        self.assertIsNone(self.module.build_vocabulary_prompt([]))
        self.assertIsNone(self.module.build_vocabulary_prompt(None))
        self.assertIsNone(self.module.build_vocabulary_prompt(["  "]))

    def test_audio_that_fits_one_whisper_window_is_not_split(self):
        audio = _speech(30.0)
        pieces = self.module.split_at_pauses(audio)
        self.assertEqual(1, len(pieces))
        self.assertEqual(len(audio), len(pieces[0]))

    def test_long_audio_is_cut_in_the_pause(self):
        import numpy as np

        audio = _speech(45.0, quiet_from=24.0, quiet_to=24.5)
        pieces = self.module.split_at_pauses(audio)
        self.assertEqual(2, len(pieces))
        self.assertGreaterEqual(len(pieces[0]) / 16000, 24.0)
        self.assertLessEqual(len(pieces[0]) / 16000, 24.5)
        np.testing.assert_array_equal(audio, np.concatenate(pieces))

    def test_every_piece_fits_one_window_even_without_pauses(self):
        import numpy as np

        audio = _speech(95.0)
        pieces = self.module.split_at_pauses(audio)
        lengths = [len(piece) / 16000 for piece in pieces]
        self.assertTrue(all(length <= 28.0 for length in lengths[:-1]), lengths)
        self.assertLessEqual(lengths[-1], 30.0)
        self.assertGreaterEqual(lengths[-1], 2.0)
        np.testing.assert_array_equal(audio, np.concatenate(pieces))

    def _fake_mlx(self, calls, texts=None):
        texts = iter(texts or [])

        def transcribe(audio, **kwargs):
            calls.append({"seconds": len(audio) / 16000, **kwargs})
            return {"text": next(texts, "hello"), "language": "en"}

        return {
            "mlx_whisper": SimpleNamespace(transcribe=transcribe),
            "mlx": SimpleNamespace(core=SimpleNamespace(clear_cache=lambda: None)),
        }

    def test_mlx_transcribe_passes_the_prompt_to_whisper(self):
        calls = []
        with mock.patch.dict(sys.modules, self._fake_mlx(calls)):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            model.transcribe(_speech(3.0), language="en", initial_prompt="Convex, Tailscale.")

        self.assertEqual(1, len(calls))
        self.assertEqual("Convex, Tailscale.", calls[0]["initial_prompt"])

    def test_mlx_transcribe_without_a_prompt_leaves_long_audio_to_whisper(self):
        calls = []
        with mock.patch.dict(sys.modules, self._fake_mlx(calls)):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            model.transcribe(_speech(45.0, quiet_from=24.0, quiet_to=24.5), language="en")

        self.assertEqual(1, len(calls))
        self.assertAlmostEqual(45.0, calls[0]["seconds"])
        self.assertIsNone(calls[0]["initial_prompt"])

    def test_mlx_transcribe_gives_the_prompt_to_every_window_of_long_audio(self):
        # Whisper drops the initial prompt after its first 30 second window
        # when condition_on_previous_text is off, so long dictations lost
        # their capitals and punctuation part way through.
        calls = []
        fake = self._fake_mlx(calls, texts=["First part.", "Second part."])
        with mock.patch.dict(sys.modules, fake):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            segments, _info = model.transcribe(
                _speech(45.0, quiet_from=24.0, quiet_to=24.5),
                language="en",
                initial_prompt="Convex.",
            )

        self.assertEqual(2, len(calls))
        self.assertEqual(["Convex.", "Convex."], [call["initial_prompt"] for call in calls])
        self.assertEqual(["First part.", "Second part."], [segment.text for segment in segments])

    def test_mlx_only_asks_for_word_timings_when_wanted(self):
        calls = []
        with mock.patch.dict(sys.modules, self._fake_mlx(calls)):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            model.transcribe(_speech(3.0), language="en")
            model.transcribe(_speech(3.0), language="en", word_timestamps=True)

        self.assertNotIn("word_timestamps", calls[0])
        self.assertTrue(calls[1]["word_timestamps"])

    def test_mlx_word_timings_are_offset_for_each_window_of_long_audio(self):
        results = iter([
            {"segments": [{"text": " First", "start": 0.5, "end": 1.0,
                           "words": [{"word": " First", "start": 0.5, "end": 1.0}]}]},
            {"segments": [{"text": " Second", "start": 0.2, "end": 0.9,
                           "words": [{"word": " Second", "start": 0.2, "end": 0.9}]}]},
        ])
        fake = {
            "mlx_whisper": SimpleNamespace(transcribe=lambda audio, **kwargs: next(results)),
            "mlx": SimpleNamespace(core=SimpleNamespace(clear_cache=lambda: None)),
        }
        with mock.patch.dict(sys.modules, fake):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            segments, _info = model.transcribe(
                _speech(45.0, quiet_from=24.0, quiet_to=24.5),
                language="en",
                initial_prompt="Convex.",
                word_timestamps=True,
            )

        self.assertEqual(0.5, segments[0].words[0].start)
        second = segments[1].words[0]
        self.assertGreater(second.start, 24.0)
        self.assertLess(second.start, 25.0)
        self.assertAlmostEqual(segments[1].start, second.start)


if __name__ == "__main__":
    unittest.main()
