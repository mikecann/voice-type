"""Audio-level guards for voice-type recordings."""


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
