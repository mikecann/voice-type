from __future__ import annotations

import sys


WAKE_RESUME_GAP_SECONDS = 30.0
PREVIEW_OUTPUT_MODES = frozenset({"final_only", "hybrid", "stabilized", "precompute"})


def should_prepare_mic_stream(platform_name: str) -> bool:
    """Open the mic stream ahead of key-down without starting it.

    Only the running stream shows the privacy indicator. This is checked on
    macOS; Windows keeps opening the stream on key-down until it is tested.
    """
    return platform_name == "darwin"


def should_prepare_mic_stream_local() -> bool:
    return should_prepare_mic_stream(sys.platform)


def should_stream_preview(output_mode: str) -> bool:
    """Return whether a recording mode should update the transcript overlay.

    Output modes control finalization and text injection. They do not change
    the user's expectation that speech appears in the live preview.
    """
    return output_mode in PREVIEW_OUTPUT_MODES


def should_restart_after_loop_gap(
    *,
    platform_name: str,
    previous_wall_time: float,
    current_wall_time: float,
) -> bool:
    if platform_name != "darwin":
        return False
    gap = current_wall_time - previous_wall_time
    return gap > WAKE_RESUME_GAP_SECONDS
