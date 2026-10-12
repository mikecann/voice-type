from __future__ import annotations

import importlib.util
import platform as host_platform
import threading
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16000

# mlx.core.clear_cache() affects the whole process, not one model instance.
# Preview and final models therefore share a lock even when they use different
# Whisper weights. Otherwise one thread can clear native working memory while
# the other is still running inference.
_MLX_INFERENCE_LOCK = threading.Lock()

MLX_REPOS_BY_MODEL = {
    "tiny.en": "mlx-community/whisper-tiny.en-mlx",
    "base.en": "mlx-community/whisper-base.en-mlx",
    "small.en": "mlx-community/whisper-small.en-mlx",
    "medium.en": "mlx-community/whisper-medium-mlx",
    "large-v2": "mlx-community/whisper-large-v2-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
}


def has_mlx_whisper() -> bool:
    return importlib.util.find_spec("mlx_whisper") is not None


def resolve_mlx_repo(
    *,
    system: str,
    machine: str,
    model_name: str,
    has_mlx: bool | None = None,
) -> str | None:
    if system != "darwin":
        return None

    normalized_machine = machine.lower()
    if normalized_machine not in {"arm64", "aarch64"}:
        return None

    if has_mlx is None:
        has_mlx = has_mlx_whisper()
    if not has_mlx:
        return None

    return MLX_REPOS_BY_MODEL.get(model_name)


def resolve_local_mlx_repo(*, model_name: str) -> str | None:
    return resolve_mlx_repo(
        system=host_platform.system().lower(),
        machine=host_platform.machine(),
        model_name=model_name,
    )


def resolve_default_whisper_model(
    *,
    accelerated_model: str,
    fallback_model: str,
    cuda_available: bool,
    system: str,
    machine: str,
    has_mlx: bool | None = None,
) -> str:
    """Choose the accelerated model when the current hardware supports it."""
    if cuda_available:
        return accelerated_model

    mlx_repo = resolve_mlx_repo(
        system=system,
        machine=machine,
        model_name=accelerated_model,
        has_mlx=has_mlx,
    )
    return accelerated_model if mlx_repo else fallback_model


def resolve_local_default_whisper_model(
    *,
    accelerated_model: str,
    fallback_model: str,
    cuda_available: bool,
) -> str:
    return resolve_default_whisper_model(
        accelerated_model=accelerated_model,
        fallback_model=fallback_model,
        cuda_available=cuda_available,
        system=host_platform.system().lower(),
        machine=host_platform.machine(),
    )


def build_vocabulary_prompt(words) -> str | None:
    """Turn the vocabulary setting into Whisper's initial prompt.

    A backtest on Mike's own recordings found a prompt like "Convex, Tailscale,
    Sammy Cam." fixed most misheard names and kept capitals and punctuation on
    short dictations, where Whisper otherwise drops them about a third of the time.
    """
    seen: set[str] = set()
    cleaned = []
    for word in words or []:
        word = str(word).strip()
        if word and word.casefold() not in seen:
            seen.add(word.casefold())
            cleaned.append(word)
    return ", ".join(cleaned) + "." if cleaned else None


WHISPER_WINDOW_SECONDS = 30.0
PROMPTED_PIECE_SECONDS = 28.0
PAUSE_SEARCH_SECONDS = 8.0
PAUSE_FRAME_SECONDS = 0.1


def split_at_pauses(audio: np.ndarray) -> list[np.ndarray]:
    """Cut audio longer than one Whisper window at its quietest moments.

    Each piece except the last is at most PROMPTED_PIECE_SECONDS. The cut is
    the quietest frame in the last PAUSE_SEARCH_SECONDS of that span, which in
    natural speech is almost always a pause between words.
    """
    window = int(WHISPER_WINDOW_SECONDS * SAMPLE_RATE)
    piece = int(PROMPTED_PIECE_SECONDS * SAMPLE_RATE)
    search = int(PAUSE_SEARCH_SECONDS * SAMPLE_RATE)
    frame = int(PAUSE_FRAME_SECONDS * SAMPLE_RATE)

    pieces = []
    start = 0
    while len(audio) - start > window:
        lo = start + piece - search
        span = audio[lo:start + piece]
        frames = len(span) // frame
        energy = np.square(span[: frames * frame].reshape(frames, frame)).mean(axis=1)
        cut = lo + int(np.argmin(energy)) * frame + frame // 2
        pieces.append(audio[start:cut])
        start = cut
    pieces.append(audio[start:])
    return pieces


@dataclass(frozen=True)
class MlxSegment:
    text: str


@dataclass(frozen=True)
class MlxInfo:
    language: str
    language_probability: float


class MlxWhisperModel:
    def __init__(self, *, repo_id: str):
        from mlx import core as mlx_core
        import mlx_whisper

        self._mlx_core = mlx_core
        self._mlx_whisper = mlx_whisper
        self.repo_id = repo_id
        self._is_warmed = False
        self._inference_lock = _MLX_INFERENCE_LOCK

    def warm(self) -> None:
        if self._is_warmed:
            return

        silence = np.zeros(int(0.5 * SAMPLE_RATE), dtype=np.float32)
        self.transcribe(
            silence,
            language="en",
            condition_on_previous_text=False,
            verbose=False,
        )
        self._is_warmed = True

    def transcribe(self, audio, **kwargs):
        audio = np.asarray(audio, dtype=np.float32)
        prompt = kwargs.get("initial_prompt")
        # Whisper only applies the initial prompt to its first 30 second
        # window when condition_on_previous_text is off. Transcribing each
        # window-sized piece separately gives every piece the prompt.
        pieces = split_at_pauses(audio) if prompt else [audio]
        with self._inference_lock:
            try:
                segments = []
                first_result = None
                for piece in pieces:
                    result = self._mlx_whisper.transcribe(
                        piece,
                        path_or_hf_repo=self.repo_id,
                        language=kwargs.get("language", "en"),
                        condition_on_previous_text=kwargs.get("condition_on_previous_text", False),
                        verbose=kwargs.get("verbose", False),
                        initial_prompt=prompt,
                    )
                    first_result = first_result or result
                    segments.extend(self._segments_from_result(result))
                info = MlxInfo(
                    language=str(first_result.get("language") or "en"),
                    language_probability=float(first_result.get("language_probability") or 1.0),
                )
                return segments, info
            finally:
                self._mlx_core.clear_cache()

    def _segments_from_result(self, result: dict) -> list[MlxSegment]:
        parts = [
            MlxSegment(str(segment.get("text", "")).strip())
            for segment in result.get("segments", [])
            if str(segment.get("text", "")).strip()
        ]
        if parts:
            return parts

        text = str(result.get("text") or "").strip()
        if not text:
            return []
        return [MlxSegment(text)]


def load_local_mlx_model(
    *,
    model_name: str,
    repo_resolver=None,
    model_factory=None,
):
    """Load and warm an MLX Whisper model, or return None off Apple Silicon."""
    if repo_resolver is None:
        repo_resolver = resolve_local_mlx_repo
    if model_factory is None:
        model_factory = MlxWhisperModel

    repo_id = repo_resolver(model_name=model_name)
    if not repo_id:
        return None

    model = model_factory(repo_id=repo_id)
    model.warm()
    return model
