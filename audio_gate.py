"""Audio-level guards for voice-type recordings."""

import re


FLATLINE_RECORDING_MESSAGE = "No microphone audio\nRelease to restart"
FLATLINE_RECOVERY_MESSAGE = "No microphone audio\nRestarting Voice Type..."


def is_flatline_audio_capture(
    *,
    duration_sec: float,
    rms: float,
    peak: float,
    min_duration_sec: float = 0.5,
    max_rms: float = 0.000001,
    max_peak: float = 0.00001,
) -> bool:
    """Return True when an open microphone stream delivered digital silence.

    A real microphone has a small noise floor even in a quiet room. A sustained
    stream of effectively zero-valued samples means CoreAudio opened a device
    that is not actually delivering audio, which can happen after macOS wakes.
    """
    return (
        duration_sec >= min_duration_sec
        and rms <= max_rms
        and peak <= max_peak
    )


def should_skip_short_low_level_audio(
    *,
    duration_sec: float,
    rms: float,
    peak: float,
    max_duration_sec: float = 1.0,
    max_rms: float = 0.004,
    max_peak: float = 0.012,
    tap_duration_sec: float = 0.4,
    tap_max_peak: float = 0.03,
) -> bool:
    """Return True for very short, near-silent clips likely to hallucinate.

    On the Yeti, short phrases like "same here" peak around 0.02 to 0.03,
    while real silence peaks below 0.008, so the peak limit sits between them.
    Accidental taps under 0.4s keep the stricter limit, since Whisper turns
    those into "Thank you." and no real dictation is that short.
    """
    limit = tap_max_peak if duration_sec < tap_duration_sec else max_peak
    return (
        duration_sec < max_duration_sec
        and rms < max_rms
        and peak < limit
    )


# Whisper sometimes gets stuck on near-silent or clipped audio and repeats one
# word or phrase hundreds of times ("making making making...", "Call us Call
# us..."), even with its own compression-ratio fallback. Nobody repeats a
# phrase 8 times back to back in dictation, and 4 times only counts when it
# came out faster than anyone talks, so "no, no, no, no" survives.
_LOOP_WORD = re.compile(r"[a-z0-9']+")
_LOOP_MAX_NGRAM = 4
_LOOP_ALWAYS_REPEATS = 8
_LOOP_FAST_REPEATS = 4
_LOOP_FAST_WORDS_PER_SEC = 6.0


def _loop_key(token: str) -> str:
    words = _LOOP_WORD.findall(token.lower())
    return " ".join(words) if words else token


def guard_repetition_loops(text: str, *, duration_sec: float | None = None) -> str:
    """Collapse Whisper's runaway repeats, or drop text that is only a loop.

    Each run of a 1 to 4 word phrase repeated back to back enough times is
    cut down to a single copy. If nothing else is left, the clip is treated
    as a hallucination and "" is returned, so nothing gets pasted.
    """
    tokens = text.split()
    if len(tokens) < _LOOP_FAST_REPEATS:
        return text
    keys = [_loop_key(token) for token in tokens]
    too_fast = bool(duration_sec) and len(tokens) / duration_sec > _LOOP_FAST_WORDS_PER_SEC
    min_repeats = _LOOP_FAST_REPEATS if too_fast else _LOOP_ALWAYS_REPEATS

    kept: list[str] = []
    looped = False
    other_words = 0
    i = 0
    while i < len(tokens):
        best = None
        for n in range(1, _LOOP_MAX_NGRAM + 1):
            phrase = keys[i:i + n]
            if len(phrase) < n:
                break
            repeats = 1
            while keys[i + repeats * n:i + (repeats + 1) * n] == phrase:
                repeats += 1
            if repeats >= min_repeats and (best is None or repeats * n > best[0] * best[1]):
                best = (repeats, n)
        if best is None:
            kept.append(tokens[i])
            other_words += 1
            i += 1
            continue
        repeats, n = best
        looped = True
        kept.extend(tokens[i:i + n])
        i += repeats * n
        # A loop usually stops part way through the phrase ("Call us Call").
        phrase = keys[i - n:i]
        tail = 0
        while tail < n - 1 and i + tail < len(keys) and keys[i + tail] == phrase[tail]:
            tail += 1
        i += tail
    if not looped:
        return text
    if other_words < 2:
        return ""
    return " ".join(kept)
