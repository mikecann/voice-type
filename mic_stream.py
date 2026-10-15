from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Any, Callable


@dataclass(frozen=True)
class OpenedStream:
    stream: Any
    device_name: str
    # False for the system default or a fallback microphone. Those can change
    # between recordings, so the next key-down resolves the device again.
    reusable: bool


class MicStream:
    """Decide when the push-to-talk input stream is opened, started and closed.

    With prepare_ahead the stream is opened while idle and only started on
    key-down. macOS shows the orange microphone dot only while input is
    running, so an opened stream stays invisible, and key-down skips the
    ~35 ms PortAudio takes to open one. Speech in that gap was being lost from
    the start of short dictations. Without prepare_ahead the stream is opened
    on key-down and closed on key-up.
    """

    def __init__(
        self,
        *,
        open_stream: Callable[[], OpenedStream],
        refresh_devices: Callable[[], None],
        run_bounded: Callable[[Callable[[], None]], bool],
        prepare_ahead: bool,
    ) -> None:
        self._open_stream = open_stream
        self._refresh_devices = refresh_devices
        # Runs a CoreAudio stop/close off-thread; False means it timed out.
        self._run_bounded = run_bounded
        self._prepare_ahead = prepare_ahead
        self._lock = threading.RLock()
        self._opened: OpenedStream | None = None
        self._device_name = ""
        self._running = False
        self._stale = False
        self._error = False

    @property
    def device_name(self) -> str:
        return self._device_name

    @property
    def is_running(self) -> bool:
        return self._running

    def note_error(self) -> None:
        """Called from the audio callback when PortAudio reports a problem."""
        self._error = True

    def invalidate(self) -> None:
        """Open a fresh stream next time, e.g. after a mic or dock change."""
        self._stale = True

    def prepare(self) -> None:
        """Open, but don't start, the stream for the next recording."""
        if not self._prepare_ahead:
            return
        with self._lock:
            if self._running or self._is_reusable():
                return
            if self._opened is not None and not self._stale and not self._error:
                # Key-down resolves this device again anyway, so opening
                # another one now would only be thrown away.
                return
            self._close()
            self._open()

    def start(self) -> bool:
        """Start capturing. Returns whether a prepared stream was reused."""
        with self._lock:
            reused = self._is_reusable()
            if not reused:
                self._close()
                self._open()
            try:
                self._opened.stream.start()
            except Exception:
                self._close()
                if not reused:
                    raise
                # A prepared stream can go bad while idle, for example if its
                # device was unplugged. Retry once with a fresh one.
                reused = False
                self._open()
                try:
                    self._opened.stream.start()
                except Exception:
                    self._close()
                    raise
            self._running = True
            return reused

    def stop(self) -> None:
        with self._lock:
            if self._opened is None:
                return
            if not self._prepare_ahead:
                self._close()
                return
            if not self._running:
                return
            self._running = False
            if not self._run_bounded(self._opened.stream.stop):
                # The stop is wedged in CoreAudio. Leak it, like a timed-out
                # close, and let the next start open a fresh stream.
                self._opened = None

    def refresh_devices(self) -> bool:
        """Refresh PortAudio's device list unless a recording is running.

        PortAudio's terminate frees every open stream, so the prepared one is
        closed first. Call prepare() afterwards to open it again.
        """
        with self._lock:
            if self._running:
                return False
            self._close()
            self._refresh_devices()
            return True

    def close(self) -> None:
        with self._lock:
            self._close()

    def _is_reusable(self) -> bool:
        return (
            self._opened is not None
            and self._opened.reusable
            and not self._stale
            and not self._error
        )

    def _open(self) -> None:
        # Clear first so an invalidate() that lands while opening still counts.
        self._stale = False
        self._error = False
        self._opened = self._open_stream()
        self._device_name = self._opened.device_name

    def _close(self) -> None:
        opened, self._opened = self._opened, None
        self._running = False
        if opened is None:
            return
        stream = opened.stream

        def _stop_and_close():
            stream.stop()
            stream.close()

        self._run_bounded(_stop_and_close)
