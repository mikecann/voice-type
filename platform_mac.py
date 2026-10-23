"""macOS platform implementations for voice-type."""

from __future__ import annotations

import os
import subprocess
import threading
from typing import Callable

_LAUNCH_AGENT_LABEL = "com.mikerosoft.voice-type"

_listener_started = False
_hotkey_listener_state = "not-started"
_hotkey_listener_state_lock = threading.Lock()
_lifecycle_lock = threading.Lock()
_wake_generation = 0
_display_generation = 0
_lifecycle_observers: list[tuple[object, object]] = []

# The app that was frontmost when the push-to-talk key went down.
# Saved before our overlay can steal focus; re-activated before pasting.
_target_app: object = None

# macOS virtual keycodes for the two push-to-talk keys.
_VK_F12 = 111
_VK_RIGHT_CONTROL = 0x3E
_DEVICE_RIGHT_CONTROL_MASK = 0x00002000


def reduce_motion_enabled() -> bool:
    from AppKit import NSWorkspace

    return bool(NSWorkspace.sharedWorkspace().accessibilityDisplayShouldReduceMotion())


class MacPushToTalkHotkeys:
    """Track the macOS keys reserved for push-to-talk."""

    def __init__(self) -> None:
        self._down: set[int] = set()
        self._lock = threading.Lock()

    def handle_event(
        self,
        event_kind: str,
        keycode: int,
        physical_down: bool | None = None,
    ) -> bool:
        """Update key state and return whether the event was handled."""
        if keycode == _VK_F12:
            if event_kind == "key_down":
                physical_down = True
            elif event_kind == "key_up":
                physical_down = False
            else:
                return False
        elif keycode == _VK_RIGHT_CONTROL:
            if event_kind != "flags_changed" or physical_down is None:
                return False
        else:
            return False

        with self._lock:
            if physical_down:
                self._down.add(keycode)
            else:
                self._down.discard(keycode)
        return True

    def is_down(self) -> bool:
        with self._lock:
            return bool(self._down)

    def reset(self) -> None:
        with self._lock:
            self._down.clear()


_hotkeys = MacPushToTalkHotkeys()


# ---------------------------------------------------------------------------
# Draw while dictating — the mouse is a pen while push-to-talk is held.
#
# A second event tap watches only left mouse down, drag and up, and is only
# enabled while a drawing session is live, so normal mouse use never goes
# through Python. Plain movement isn't in its mask at all, so the cursor
# moves as usual even while drawing.
#
# The tap callback only records points under a lock and hands finished
# strokes to a queue. Drawing happens on the main thread, capture on its own
# worker, both well away from the tap's watchdog.
# ---------------------------------------------------------------------------

# A mouse-up still owed to us after the key went up mid-drag is given up on
# after this long, so the mouse can never stay swallowed.
_PENDING_MOUSE_UP_TIMEOUT = 5.0
# Skip drag samples closer than this to the previous one (points).
_MIN_SAMPLE_SPACING = 1.0


class MacInkTracker:
    """Turn mouse events into strokes while a drawing session is live.

    `handle_mouse` returns (swallow, keep_tap). The caller swallows the event
    when told to, and disables the mouse tap once keep_tap is False.
    """

    def __init__(self, *, clock=None, max_marks: int = 10, on_stroke=None) -> None:
        import time
        self._clock = clock or time.monotonic
        self._max_marks = max_marks
        self.on_stroke = on_stroke
        self._lock = threading.Lock()
        self._active = False
        self._current: list[tuple[float, float]] | None = None
        self._current_started = 0.0
        self._strokes: list = []
        self._recorded = 0
        self._pending_up_since: float | None = None
        # Whether the button is down on a press we swallowed. A drag that was
        # already under way at key-down belongs to the app, not to us.
        self._holding_down = False
        self._version = 0

    def begin(self) -> None:
        with self._lock:
            self._active = True
            self._current = None
            self._strokes = []
            self._recorded = 0
            # A press swallowed in the last session whose mouse-up hasn't come
            # yet is still ours: the app never saw its mouse-down.
            self._holding_down = self._pending_up_since is not None
            self._pending_up_since = None
            self._version += 1

    def resume(self) -> bool:
        """Pick the session back up, keeping its marks. Returns whether it
        had stopped.

        For a key let go and pressed again so fast that the worker never saw
        it up: the tap thread ended drawing, but the recording carries on.
        """
        with self._lock:
            if self._active:
                return False
            self._active = True
            self._holding_down = self._pending_up_since is not None
            self._pending_up_since = None
            self._version += 1
            return True

    def forget_button(self) -> None:
        """Stop claiming the button after the tap missed events.

        While the tap was off the app may have seen a mouse-up and a fresh
        mouse-down, so swallowing the next mouse-up could leave it holding a
        button. The mark in progress ends where it got to.
        """
        finished = None
        with self._lock:
            if self._current is not None:
                finished = self._finish_locked()
            self._holding_down = False
            self._pending_up_since = None
            self._version += 1
        self._announce(finished)

    def end(self) -> bool:
        """End the session. Returns whether the tap must stay on for a mouse-up."""
        finished = None
        with self._lock:
            if not self._active:
                return self._pending_up_since is not None
            self._active = False
            if self._holding_down:
                # Key released mid-drag: the mark ends here, but the app
                # never saw the mouse-down, so its mouse-up is ours too.
                if self._current is not None:
                    finished = self._finish_locked()
                self._holding_down = False
                self._pending_up_since = self._clock()
            self._version += 1
            keep = self._pending_up_since is not None
        self._announce(finished)
        return keep

    def reset(self) -> None:
        """Forget everything and stop swallowing, e.g. after a tap timeout."""
        with self._lock:
            self._active = False
            self._current = None
            self._strokes = []
            self._pending_up_since = None
            self._holding_down = False
            self._version += 1

    def is_active(self) -> bool:
        with self._lock:
            return self._active

    def needs_tap(self) -> bool:
        with self._lock:
            return self._active or self._pending_up_since is not None

    def expire_pending_up(self) -> bool:
        """Drop an owed mouse-up that never came. Returns whether the tap can go."""
        with self._lock:
            if self._active:
                return False
            if (
                self._pending_up_since is not None
                and self._clock() - self._pending_up_since > _PENDING_MOUSE_UP_TIMEOUT
            ):
                self._pending_up_since = None
            return self._pending_up_since is None

    def handle_mouse(self, kind: str, x: float, y: float) -> tuple[bool, bool]:
        finished = None
        with self._lock:
            if not self._active:
                if self._pending_up_since is None:
                    return False, False
                if kind == "down":
                    # A fresh click after the session: the owed mouse-up is
                    # lost somewhere, so let this click through as normal.
                    self._pending_up_since = None
                    return False, False
                if kind == "up":
                    self._pending_up_since = None
                    return True, False
                return True, True

            if kind != "down" and not self._holding_down:
                # The app saw this drag's mouse-down before the key went
                # down, so let the rest of it through.
                return False, True
            if kind == "down":
                self._holding_down = True
                if self._current is not None:
                    finished = self._finish_locked()
                if self._recorded < self._max_marks:
                    self._current = [(x, y)]
                    self._current_started = self._clock()
            elif kind == "drag":
                if self._current is not None:
                    last = self._current[-1]
                    if abs(x - last[0]) + abs(y - last[1]) >= _MIN_SAMPLE_SPACING:
                        self._current.append((x, y))
            elif kind == "up":
                self._holding_down = False
                if self._current is not None:
                    self._current.append((x, y))
                    finished = self._finish_locked()
            self._version += 1
        self._announce(finished)
        return True, True

    def _finish_locked(self):
        from screen_marks import Stroke
        self._recorded += 1
        stroke = Stroke(
            points=self._current,
            started_at=self._current_started,
            ended_at=self._clock(),
            number=self._recorded,
        )
        self._strokes.append(stroke)
        self._current = None
        return stroke

    def _announce(self, stroke) -> None:
        # Outside the lock: the callback only puts the stroke on a queue.
        if stroke is not None and self.on_stroke is not None:
            try:
                self.on_stroke(stroke)
            except Exception:
                pass

    def take_strokes(self) -> list:
        with self._lock:
            strokes, self._strokes = self._strokes, []
            self._version += 1
            return strokes

    def snapshot(self) -> tuple[int, list, list | None]:
        """(version, finished strokes, in-progress points) for drawing."""
        with self._lock:
            current = list(self._current) if self._current is not None else None
            return self._version, list(self._strokes), current


_ink = MacInkTracker()
_ink_lock = threading.Lock()
_mouse_tap = None
_drawing_enabled = False


_mouse_tap_on = False


def _set_mouse_tap(enabled: bool) -> None:
    global _mouse_tap_on
    tap = _mouse_tap
    if tap is None:
        return
    # The watchdog asks for "off" every loop tick; only talk to the window
    # server when the state actually changes.
    if enabled == _mouse_tap_on and not enabled:
        return
    try:
        import Quartz
        Quartz.CGEventTapEnable(tap, enabled)
        _mouse_tap_on = enabled
    except Exception:
        pass


def _release_drawing() -> None:
    """End the drawing session as the key goes up. Safe on the tap thread."""
    with _ink_lock:
        keep = _ink.end()
    if not keep:
        _set_mouse_tap(False)


def _reset_drawing() -> None:
    """Stop drawing and let every mouse event through again."""
    with _ink_lock:
        _ink.reset()
    _set_mouse_tap(False)


def set_drawing_enabled(enabled: bool, on_stroke=None) -> None:
    """Turn draw-while-dictating on or off. `on_stroke` gets each finished mark."""
    global _drawing_enabled
    _drawing_enabled = bool(enabled)
    _ink.on_stroke = on_stroke
    if not enabled:
        _reset_drawing()


def drawing_available() -> bool:
    return _drawing_enabled and _mouse_tap is not None


def begin_drawing_session() -> bool:
    """Start a drawing session for a recording that has just started.

    Called by the main worker after key-down, never on the tap thread. If
    the key has already gone up again, nothing starts.
    """
    if not drawing_available():
        return False
    with _ink_lock:
        if not _hotkeys.is_down():
            return False
        _ink.begin()
    _set_mouse_tap(True)
    return True


def keep_drawing_session() -> None:
    """Called each worker tick while a recording with drawing is going.

    The tap thread ends drawing the instant the key goes up. If it's pressed
    again before the worker's next poll, the recording never stopped, so
    drawing has to come back too, or clicks would reach the app as
    Control-clicks.
    """
    if not _drawing_enabled or _ink.is_active():
        return
    with _ink_lock:
        if not _hotkeys.is_down() or not _ink.resume():
            return
    _set_mouse_tap(True)


def end_drawing_session() -> list:
    """End the session (if the tap thread hasn't already) and take its marks."""
    _release_drawing()
    return _ink.take_strokes()


def drawing_snapshot() -> tuple[int, list, list | None]:
    return _ink.snapshot()


def drawing_watchdog() -> None:
    """Belt and braces for the main loop: the mouse must never stay captured.

    The tap thread normally ends the session on key-up. If the key state was
    reset some other way, or an owed mouse-up never arrived, this lets the
    mouse go.
    """
    if _ink.is_active() and not _hotkeys.is_down():
        _release_drawing()
    elif not _ink.is_active() and _ink.expire_pending_up() and _mouse_tap is not None:
        if not _ink.needs_tap():
            _set_mouse_tap(False)


def _set_hotkey_listener_status(state: str) -> None:
    global _hotkey_listener_state
    with _hotkey_listener_state_lock:
        _hotkey_listener_state = state


def hotkey_listener_status() -> str:
    with _hotkey_listener_state_lock:
        return _hotkey_listener_state


def _note_system_wake(_notification) -> None:
    global _wake_generation
    with _lifecycle_lock:
        _wake_generation += 1
    _hotkeys.reset()
    _reset_drawing()


def _note_display_change(_notification) -> None:
    global _display_generation
    with _lifecycle_lock:
        _display_generation += 1


def lifecycle_event_snapshot() -> tuple[int, int]:
    """Return wake and display generations without doing work in callbacks."""
    with _lifecycle_lock:
        return _wake_generation, _display_generation


def _install_lifecycle_observers() -> None:
    if _lifecycle_observers:
        return
    try:
        from AppKit import (
            NSApplicationDidChangeScreenParametersNotification,
            NSWorkspace,
            NSWorkspaceDidWakeNotification,
        )
        from Foundation import NSNotificationCenter

        workspace_center = NSWorkspace.sharedWorkspace().notificationCenter()
        wake_token = workspace_center.addObserverForName_object_queue_usingBlock_(
            NSWorkspaceDidWakeNotification,
            None,
            None,
            _note_system_wake,
        )
        app_center = NSNotificationCenter.defaultCenter()
        display_token = app_center.addObserverForName_object_queue_usingBlock_(
            NSApplicationDidChangeScreenParametersNotification,
            None,
            None,
            _note_display_change,
        )
        _lifecycle_observers.extend(
            [(workspace_center, wake_token), (app_center, display_token)]
        )
    except Exception:
        # The wall-clock gap remains as a fallback on older PyObjC installs.
        return


def handle_quartz_hotkey_event(
    quartz,
    event_type: int,
    event,
    hotkeys: MacPushToTalkHotkeys | None = None,
) -> bool:
    """Apply one Quartz keyboard event and report whether it was handled."""
    target = hotkeys if hotkeys is not None else _hotkeys
    keycode = int(quartz.CGEventGetIntegerValueField(
        event,
        quartz.kCGKeyboardEventKeycode,
    ))

    if event_type == quartz.kCGEventKeyDown:
        event_kind = "key_down"
        physical_down = None
    elif event_type == quartz.kCGEventKeyUp:
        event_kind = "key_up"
        physical_down = None
    elif event_type == quartz.kCGEventFlagsChanged:
        event_kind = "flags_changed"
        physical_down = None
        if keycode == _VK_RIGHT_CONTROL:
            physical_down = bool(
                quartz.CGEventGetFlags(event) & _DEVICE_RIGHT_CONTROL_MASK
            )
    else:
        return False

    return target.handle_event(event_kind, keycode, physical_down)


def setup_dll_paths() -> None:
    pass


# ---------------------------------------------------------------------------
# Hotkey — CGEventTap intercepts F12 and Right Control at the system level.
#
# Using CGEventTapOptionDefault (not ListenOnly) means we can suppress the
# event by returning None from the callback, so macOS won't also handle it.
#
# Falls back to a plain pynput listener (no suppression) if the tap cannot
# be created — most likely because Accessibility permission hasn't been
# granted yet.
# ---------------------------------------------------------------------------

def _run_cg_event_tap() -> None:
    """Block the calling thread running the push-to-talk CGEventTap."""
    global _mouse_tap, _mouse_tap_on
    import Quartz

    def _callback(proxy, event_type, event, refcon):
        # macOS auto-disables an event tap if its callback is ever judged too
        # slow, or on certain user-input conditions. When that happens we stop
        # receiving events entirely — including key-up events — which could
        # leave push-to-talk stuck on. Re-enable the tap and clear key state.
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            Quartz.CGEventTapEnable(tap, True)
            _hotkeys.reset()
            # The key-up may be among the lost events, so the mouse must not
            # stay a pen.
            _reset_drawing()
            return event

        # Keep this callback minimal — any slow work here (e.g. AppKit calls)
        # risks tripping the tap watchdog. The frontmost-app snapshot is taken
        # by the main worker via snapshot_target_app() instead.
        if handle_quartz_hotkey_event(Quartz, event_type, event):
            # Stop drawing the moment the key goes up, right here rather than
            # on the worker's next poll, so a click straight after release
            # always reaches the app.
            if not _hotkeys.is_down() and _ink.needs_tap():
                _release_drawing()
            return None
        return event

    def _mouse_callback(proxy, event_type, event, refcon):
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            # Button events went straight to the app while we were off, so
            # we can't know who owns the button any more. Let it go, then
            # come back only if a session still needs us.
            _ink.forget_button()
            if _ink.needs_tap():
                Quartz.CGEventTapEnable(mouse_tap, True)
            return event
        kind = mouse_kinds.get(event_type)
        if kind is None:
            return event
        location = Quartz.CGEventGetLocation(event)
        swallow, keep = _ink.handle_mouse(kind, location.x, location.y)
        if not keep:
            _set_mouse_tap(False)
        return None if swallow else event

    mask = (
        (1 << Quartz.kCGEventKeyDown)
        | (1 << Quartz.kCGEventKeyUp)
        | (1 << Quartz.kCGEventFlagsChanged)
    )
    tap  = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap,
        Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionDefault,
        mask,
        _callback,
        None,
    )
    if tap is None:
        raise RuntimeError(
            "CGEventTapCreate returned None — grant Accessibility permission:\n"
            "  System Settings > Privacy & Security > Accessibility"
        )

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    loop   = Quartz.CFRunLoopGetCurrent()
    Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopDefaultMode)
    Quartz.CGEventTapEnable(tap, True)

    # The drawing tap shares this thread's run loop but starts disabled. It's
    # only switched on while a drawing session needs it. Any failure here
    # just turns drawing off; it must never cost us the hotkey tap.
    mouse_kinds = {
        Quartz.kCGEventLeftMouseDown: "down",
        Quartz.kCGEventLeftMouseDragged: "drag",
        Quartz.kCGEventLeftMouseUp: "up",
    }
    mouse_tap = None
    try:
        mouse_mask = 0
        for event_type in mouse_kinds:
            mouse_mask |= 1 << event_type
        mouse_tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            mouse_mask,
            _mouse_callback,
            None,
        )
        if mouse_tap is not None:
            Quartz.CGEventTapEnable(mouse_tap, False)
            mouse_source = Quartz.CFMachPortCreateRunLoopSource(None, mouse_tap, 0)
            Quartz.CFRunLoopAddSource(loop, mouse_source, Quartz.kCFRunLoopDefaultMode)
            _mouse_tap_on = False
            _mouse_tap = mouse_tap
    except Exception as exc:
        print(f"[voice-type] Mouse event tap failed ({exc}).", flush=True)
        mouse_tap = None
    if mouse_tap is None:
        print("[voice-type] Mouse event tap unavailable; drawing while dictating is off.", flush=True)
    _set_hotkey_listener_status("event-tap")
    Quartz.CFRunLoopRun()   # blocks until CFRunLoopStop is called


def _run_pynput_fallback() -> None:
    """Fallback: pynput listener — tracks key state but does not suppress events."""
    from pynput import keyboard

    def on_press(key):
        if key == keyboard.Key.f12:
            _hotkeys.handle_event("key_down", _VK_F12)
        elif key == keyboard.Key.ctrl_r:
            _hotkeys.handle_event("flags_changed", _VK_RIGHT_CONTROL, True)

    def on_release(key):
        if key == keyboard.Key.f12:
            _hotkeys.handle_event("key_up", _VK_F12)
        elif key == keyboard.Key.ctrl_r:
            _hotkeys.handle_event("flags_changed", _VK_RIGHT_CONTROL, False)

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


def _start_hotkey_listener() -> None:
    def _thread_fn():
        _set_hotkey_listener_status("starting")
        try:
            _run_cg_event_tap()
        except Exception as exc:
            _set_hotkey_listener_status("fallback")
            print(
                f"[voice-type] CGEventTap failed ({exc}); "
                "using pynput fallback (hotkey events will not be suppressed).",
                flush=True,
            )
            try:
                _run_pynput_fallback()
            except Exception as fallback_exc:
                _set_hotkey_listener_status("failed")
                print(
                    f"[voice-type] pynput hotkey fallback failed ({fallback_exc}).",
                    flush=True,
                )

    t = threading.Thread(target=_thread_fn, daemon=True, name="voice-type-hotkey")
    t.start()


def _ensure_listener() -> None:
    global _listener_started
    if not _listener_started:
        _start_hotkey_listener()
        _listener_started = True


def is_hotkey_down() -> bool:
    """Return True if F12 or Right Control is currently held."""
    _ensure_listener()
    return _hotkeys.is_down()


def snapshot_target_app() -> None:
    """Capture the frontmost app at push-to-talk key-down time.

    Called by the main worker on the key-down transition — deliberately off
    the CGEventTap callback thread, since AppKit calls there are slow enough
    to trip the tap watchdog and get the whole tap disabled.
    """
    global _target_app
    try:
        from AppKit import NSWorkspace
        _target_app = NSWorkspace.sharedWorkspace().frontmostApplication()
    except Exception:
        _target_app = None


# ---------------------------------------------------------------------------
# Monitor work area
# ---------------------------------------------------------------------------

def get_foreground_monitor_work_area() -> tuple[int, int, int, int]:
    """Return (left, top, right, bottom) of the main screen's visible work area.

    AppKit uses a bottom-left origin; we convert to the top-left origin that
    tkinter uses.  Raises on failure so Overlay._position() falls back to
    winfo_screenwidth/height.
    """
    from AppKit import NSScreen  # type: ignore[import]
    screen  = NSScreen.mainScreen()
    visible = screen.visibleFrame()
    total_h = screen.frame().size.height
    left   = int(visible.origin.x)
    top    = int(total_h - visible.origin.y - visible.size.height)
    right  = int(visible.origin.x + visible.size.width)
    bottom = int(total_h - visible.origin.y)
    return left, top, right, bottom


# ---------------------------------------------------------------------------
# Text injection via NSPasteboard + Cmd+V via direct CGEventPost
#
# pynput's Controller.type() internally calls TSM (Text Services Manager)
# APIs that are main-thread-only.  paste_text() runs on a background thread,
# which causes a SIGTRAP dispatch_assert_queue crash.
#
# Fix: copy text to NSPasteboard, then simulate Cmd+V using CGEventPost
# directly. CGEventPost is explicitly thread-safe. Every pasteboard item and
# type is saved and restored so images, files, rich text, and empty clipboards
# survive injection as well as plain text.
#
# The text is offered through a lazy data provider so we know when the target
# app actually reads it. A busy app can take longer than any fixed delay to
# handle Cmd+V, and restoring the old clipboard before it reads would paste
# the wrong thing, or nothing. If the target never reads it, the paste didn't
# land, so the text is left on the clipboard for a manual Cmd+V.
#
# A read alone doesn't prove the paste landed. Chromium apps (Claude, ChatGPT,
# Slack) read the clipboard on Cmd+V even when nothing editable has focus, so
# once the text is read, Accessibility is asked what has focus. If it isn't
# a text box, the text is left on the clipboard too.
# ---------------------------------------------------------------------------

# macOS virtual keycodes
_VK_CMD       = 55   # left Command
_VK_V         = 9    # V (QWERTY)
_VK_BACKSPACE = 51   # Delete / Backspace

_TEXT_TYPE = "public.utf8-plain-text"  # NSPasteboardTypeString
_PASTE_READ_TIMEOUT = 2.0
_PASTE_FAILED_SOUND = "/System/Library/Sounds/Funk.aiff"

_EDITABLE_ROLES = frozenset({"AXTextArea", "AXTextField", "AXComboBox"})
_AX_TIMEOUT = 0.25     # per Accessibility call, so a busy app can't stall pasting
_TEXT_BOX_WAIT = 0.5   # for an app to move a stray paste into its text box
_REFOCUS_SETTLE = 0.15  # for a re-activated app to come to the front
_FOCUS_POLL = 0.025


def _post_events(vk_sequence: list[tuple[int, bool, int]]) -> None:
    """Post a sequence of (vk, is_down, flags) keyboard events via CGEventPost."""
    import Quartz
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for vk, is_down, flags in vk_sequence:
        ev = Quartz.CGEventCreateKeyboardEvent(src, vk, is_down)
        Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _post_cmd_v() -> None:
    import Quartz
    cmd_flag = Quartz.kCGEventFlagMaskCommand
    _post_events([
        (_VK_CMD, True,  cmd_flag),
        (_VK_V,   True,  cmd_flag),
        (_VK_V,   False, cmd_flag),
        (_VK_CMD, False, 0),
    ])


def _snapshot_pasteboard(pasteboard) -> list[list[tuple[object, bytes]]]:
    """Materialize every item and type before temporarily replacing it."""
    snapshot: list[list[tuple[object, bytes]]] = []
    for item in pasteboard.pasteboardItems() or []:
        saved_types = []
        for pasteboard_type in item.types() or []:
            data = item.dataForType_(pasteboard_type)
            if data is not None:
                # Copy the bytes now. Pasteboard data providers can be lazy and
                # their objects may no longer be valid after clearContents().
                saved_types.append((pasteboard_type, bytes(data)))
        snapshot.append(saved_types)
    return snapshot


def _restore_pasteboard(pasteboard, snapshot, item_class=None) -> None:
    """Replace the pasteboard with a previously materialized snapshot."""
    if item_class is None:
        from AppKit import NSPasteboardItem
        item_class = NSPasteboardItem

    restored_items = []
    for saved_types in snapshot:
        item = item_class.alloc().init()
        for pasteboard_type, data in saved_types:
            item.setData_forType_(data, pasteboard_type)
        restored_items.append(item)

    pasteboard.clearContents()
    if restored_items:
        pasteboard.writeObjects_(restored_items)


_text_provider_class = None
# The pasteboard only holds a weak reference to its data provider.
_live_text_provider = None


def _lazy_text_item(text: str, on_read: Callable[[], None]):
    """Return a pasteboard item that supplies `text` only when asked for it.

    The provider is called on the main thread's run loop (Tk's mainloop), so
    this must never be waited on from the main thread.
    """
    global _text_provider_class, _live_text_provider
    import objc
    from AppKit import NSPasteboardItem
    from Foundation import NSObject

    if _text_provider_class is None:
        class VoiceTypeTextProvider(
            NSObject,
            protocols=[objc.protocolNamed("NSPasteboardItemDataProvider")],
        ):
            def pasteboard_item_provideDataForType_(self, _pasteboard, item, pasteboard_type):
                item.setString_forType_(self.text, pasteboard_type)
                self.on_read()

            def pasteboardFinishedWithDataProvider_(self, _pasteboard):
                pass

        _text_provider_class = VoiceTypeTextProvider

    provider = _text_provider_class.alloc().init()
    provider.text = text
    provider.on_read = on_read
    _live_text_provider = provider

    item = NSPasteboardItem.alloc().init()
    item.setDataProvider_forTypes_(provider, [_TEXT_TYPE])
    return item


def _leave_on_clipboard(pasteboard, text: str, offered: int) -> None:
    # Leave anything copied since the paste alone.
    if pasteboard.changeCount() == offered:
        # A plain string, so a manual Cmd+V (or a late read) still gets the text.
        pasteboard.clearContents()
        pasteboard.setString_forType_(text, _TEXT_TYPE)


def _paste_via_pasteboard(
    pasteboard,
    text: str,
    post_paste: Callable[[], None],
    *,
    landed: Callable[[], bool] | None = None,
    make_item=None,
    item_class=None,
    timeout: float = _PASTE_READ_TIMEOUT,
) -> tuple[float | None, bool]:
    """Paste `text` and restore the old clipboard once the target has read it.

    `landed` is asked, once the target has read the text, whether it went into
    a text box. Returns the seconds the target took to read the text (None if
    it never did) and whether the paste landed. If it didn't, the text is left
    on the clipboard.
    """
    import time
    if make_item is None:
        make_item = _lazy_text_item

    snapshot = _snapshot_pasteboard(pasteboard)
    read = threading.Event()
    pasteboard.clearContents()
    if not pasteboard.writeObjects_([make_item(text, read.set)]):
        raise RuntimeError("Could not put transcription on the pasteboard")
    offered = pasteboard.changeCount()

    started = time.perf_counter()
    post_paste()
    if not read.wait(timeout):
        _leave_on_clipboard(pasteboard, text, offered)
        return None, False
    latency = time.perf_counter() - started

    # The provider hands the data over when its callback returns.
    time.sleep(0.05)
    if landed is not None and not landed():
        _leave_on_clipboard(pasteboard, text, offered)
        return latency, False
    # Leave anything copied since the paste alone.
    if pasteboard.changeCount() == offered:
        _restore_pasteboard(pasteboard, snapshot, item_class)
    return latency, True


def _classify_focus(role: str | None, value_settable: bool) -> str:
    """Sort a focused element into "editable", "not-editable" or "unknown"."""
    if not role:
        return "unknown"
    if role in _EDITABLE_ROLES or value_settable:
        return "editable"
    return "not-editable"


def _focused_element(pid: int | None) -> tuple[str, str | None]:
    """Classify the element with keyboard focus in app `pid`, and give its role."""
    if pid is None:
        return "unknown", None
    try:
        from ApplicationServices import (
            AXUIElementCopyAttributeValue,
            AXUIElementCreateApplication,
            AXUIElementIsAttributeSettable,
            AXUIElementSetMessagingTimeout,
        )

        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, _AX_TIMEOUT)
        err, element = AXUIElementCopyAttributeValue(app, "AXFocusedUIElement", None)
        # A Chromium app that isn't frontmost, or has only just started, may
        # report no focus at all. That can't be told apart from a real miss.
        if err or element is None:
            return "unknown", None
        AXUIElementSetMessagingTimeout(element, _AX_TIMEOUT)
        err, role = AXUIElementCopyAttributeValue(element, "AXRole", None)
        if err:
            return "unknown", None
        err, settable = AXUIElementIsAttributeSettable(element, "AXValue", None)
        return _classify_focus(role, not err and bool(settable)), role
    except Exception:
        return "unknown", None


def _wait_for_text_box(
    pid: int | None,
    *,
    read_focus: Callable[[int | None], tuple[str, str | None]] | None = None,
    wait: float = _TEXT_BOX_WAIT,
    poll: float = _FOCUS_POLL,
) -> tuple[bool, str | None]:
    """Report whether a text box has focus now the target has read the paste.

    Some apps move a paste made outside their text box into it, so focus on
    something that isn't editable gets `wait` seconds to move into one. When
    Accessibility can't tell, the paste is trusted. Returns that verdict and
    the focused element's role.
    """
    import time
    if read_focus is None:
        read_focus = _focused_element

    deadline = time.monotonic() + wait
    while True:
        kind, role = read_focus(pid)
        if kind != "not-editable" or time.monotonic() >= deadline:
            return kind != "not-editable", role
        time.sleep(poll)


def _frontmost_pid() -> int | None:
    try:
        from AppKit import NSWorkspace
        return int(NSWorkspace.sharedWorkspace().frontmostApplication().processIdentifier())
    except Exception:
        return None


def inject_text(text: str, log: Callable[[str], None] | None = None) -> bool:
    import time
    from AppKit import NSPasteboard

    # Re-activate the app that had focus when recording started, in case
    # something else came to the front while the key was held.
    refocused = restore_target_app_focus()
    if refocused:
        time.sleep(_REFOCUS_SETTLE)  # wait for the app to actually come to front
    focused_role = None

    def landed() -> bool:
        nonlocal focused_role
        has_text_box, focused_role = _wait_for_text_box(_frontmost_pid())
        return has_text_box

    latency, pasted = _paste_via_pasteboard(
        NSPasteboard.generalPasteboard(), text, _post_cmd_v, landed=landed,
    )
    if not pasted:
        subprocess.Popen(["afplay", _PASTE_FAILED_SOUND])
        if log and latency is None:
            log(
                f"Paste not confirmed: target never read the clipboard within "
                f"{_PASTE_READ_TIMEOUT:.1f}s. Text left on the clipboard "
                f"({len(text)} chars)."
            )
        elif log:
            log(
                f"Paste went nowhere: the target read the clipboard but no text "
                f"box had focus ({focused_role}). Text left on the clipboard "
                f"({len(text)} chars)."
            )
        return False
    if log:
        log(f"NSPasteboard+Cmd+V: {len(text)} chars injected "
            f"(target read clipboard after {latency * 1000:.0f}ms, "
            f"focus {focused_role or 'unknown'}"
            f"{', refocused target' if refocused else ''})")
    return True


# ---------------------------------------------------------------------------
# Text plus screenshots
#
# Marks from drawing while dictating are pasted as separate Cmd+V presses:
# the text first, then each PNG in order. Electron/Chromium composers (T3
# Code, Slack, Chrome web apps) turn a pasted image into an attachment, but
# only one image per paste and only if the clipboard still holds it when
# their paste handler runs, so each item waits to be read and then gets a
# short gap before the next one replaces it. The old clipboard is restored
# once, after the last item, so clipboard managers see one round trip.
#
# Dictations without marks never come through here; they keep inject_text.
# ---------------------------------------------------------------------------

_PNG_TYPE = "public.png"
_IMAGE_PASTE_GAP = 0.35
_data_provider_class = None
_live_data_providers: list = []


def _lazy_data_item(payload, pasteboard_type: str, on_read: Callable[[], None]):
    """Like _lazy_text_item, for text or PNG bytes."""
    global _data_provider_class
    import objc
    from AppKit import NSPasteboardItem
    from Foundation import NSData, NSObject

    if _data_provider_class is None:
        class VoiceTypeDataProvider(
            NSObject,
            protocols=[objc.protocolNamed("NSPasteboardItemDataProvider")],
        ):
            def pasteboard_item_provideDataForType_(self, _pasteboard, item, requested_type):
                if isinstance(self.payload, str):
                    item.setString_forType_(self.payload, requested_type)
                else:
                    item.setData_forType_(
                        NSData.dataWithBytes_length_(self.payload, len(self.payload)),
                        requested_type,
                    )
                self.on_read()

            def pasteboardFinishedWithDataProvider_(self, _pasteboard):
                pass

        _data_provider_class = VoiceTypeDataProvider

    provider = _data_provider_class.alloc().init()
    provider.payload = payload
    provider.on_read = on_read
    # The pasteboard holds providers weakly; keep this sequence's alive.
    _live_data_providers[:] = [provider]

    item = NSPasteboardItem.alloc().init()
    item.setDataProvider_forTypes_(provider, [pasteboard_type])
    return item


def _leave_item_on_clipboard(pasteboard, payload, pasteboard_type: str, offered: int) -> None:
    if pasteboard.changeCount() != offered:
        return
    pasteboard.clearContents()
    if isinstance(payload, str):
        pasteboard.setString_forType_(payload, pasteboard_type)
    else:
        from Foundation import NSData
        pasteboard.setData_forType_(
            NSData.dataWithBytes_length_(payload, len(payload)), pasteboard_type,
        )


def _paste_sequence_via_pasteboard(
    pasteboard,
    items: list[tuple[object, str]],
    post_paste: Callable[[], None],
    *,
    landed: Callable[[], bool] | None = None,
    make_item=None,
    item_class=None,
    leave_on_clipboard=None,
    timeout: float = _PASTE_READ_TIMEOUT,
    gap: float = _IMAGE_PASTE_GAP,
    sleep=None,
) -> tuple[int, bool]:
    """Paste each (payload, type) in order, then restore the clipboard once.

    `landed` is asked after the first item is read, like _paste_via_pasteboard.
    Returns how many items the target read and whether everything landed.
    If something didn't, that item is left on the clipboard and the rest are
    skipped; the screenshots are still on disk.
    """
    import time
    if make_item is None:
        make_item = _lazy_data_item
    if leave_on_clipboard is None:
        leave_on_clipboard = _leave_item_on_clipboard
    if sleep is None:
        sleep = time.sleep
    if not items:
        return 0, True

    snapshot = _snapshot_pasteboard(pasteboard)
    offered = pasteboard.changeCount()
    for index, (payload, pasteboard_type) in enumerate(items):
        if index:
            sleep(gap)
            if pasteboard.changeCount() != offered:
                # Something else was copied mid-sequence. It's the user's
                # clipboard now: stop without touching it or restoring over it.
                return index, False
        read = threading.Event()
        pasteboard.clearContents()
        if not pasteboard.writeObjects_([make_item(payload, pasteboard_type, read.set)]):
            raise RuntimeError("Could not put the paste on the pasteboard")
        offered = pasteboard.changeCount()
        post_paste()
        if not read.wait(timeout):
            leave_on_clipboard(pasteboard, payload, pasteboard_type, offered)
            return index, False
        # The provider hands the data over when its callback returns.
        sleep(0.05)
        if index == 0 and landed is not None and not landed():
            leave_on_clipboard(pasteboard, payload, pasteboard_type, offered)
            return 1, False
    if items and items[-1][1] != _TEXT_TYPE:
        # Chromium reads the image, then builds the attachment on a later
        # task. Restoring straight away is fine for text, but give the last
        # image the same breathing room as the ones before it.
        sleep(gap)
    if pasteboard.changeCount() == offered:
        _restore_pasteboard(pasteboard, snapshot, item_class)
    return len(items), True


def inject_text_and_images(
    text: str,
    images: list[bytes],
    log: Callable[[str], None] | None = None,
) -> bool:
    """Paste dictated text (if any) followed by each PNG, in order."""
    import time
    from AppKit import NSPasteboard

    refocused = restore_target_app_focus()
    if refocused:
        time.sleep(_REFOCUS_SETTLE)
    focused_role = None

    def landed() -> bool:
        nonlocal focused_role
        has_text_box, focused_role = _wait_for_text_box(_frontmost_pid())
        return has_text_box

    items: list[tuple[object, str]] = []
    if text.strip():
        items.append((text, _TEXT_TYPE))
    items.extend((png, _PNG_TYPE) for png in images)
    pasted, ok = _paste_sequence_via_pasteboard(
        NSPasteboard.generalPasteboard(),
        items,
        _post_cmd_v,
        landed=landed if text.strip() else None,
    )
    if not ok:
        subprocess.Popen(["afplay", _PASTE_FAILED_SOUND])
        if log:
            log(
                f"Paste with screenshots stopped after {pasted} of {len(items)} "
                f"item(s) (focus {focused_role or 'unknown'}). The next item is "
                "left on the clipboard."
            )
        return False
    if log:
        log(
            f"NSPasteboard+Cmd+V: {len(text)} chars and {len(images)} "
            f"screenshot(s) injected (focus {focused_role or 'unknown'}"
            f"{', refocused target' if refocused else ''})"
        )
    return True


def screen_capture_allowed() -> bool:
    """Whether Voice Type may capture other apps' windows (Screen Recording)."""
    try:
        import Quartz
        return bool(Quartz.CGPreflightScreenCaptureAccess())
    except Exception:
        return False


def request_screen_capture() -> None:
    """Ask macOS for Screen Recording. Shows the system prompt the first time."""
    try:
        import Quartz
        Quartz.CGRequestScreenCaptureAccess()
    except Exception:
        pass


def inject_backspaces(count: int, log: Callable[[str], None] | None = None) -> None:
    if count <= 0:
        return
    events = []
    for _ in range(count):
        events.append((_VK_BACKSPACE, True,  0))
        events.append((_VK_BACKSPACE, False, 0))
    _post_events(events)
    if log:
        log(f"CGEventPost: {count} backspace(s) injected")


def restore_target_app_focus(*, frontmost_pid: Callable[[], int | None] | None = None) -> bool:
    """Bring the key-down app back to the front. Returns whether it had to.

    The overlay never takes focus, so the app is usually still in front and
    re-activating it would only add a wait before every paste.
    """
    if _target_app is None:
        return False
    if frontmost_pid is None:
        frontmost_pid = _frontmost_pid
    try:
        if frontmost_pid() == int(_target_app.processIdentifier()):
            return False
    except Exception:
        pass
    try:
        _NSApplicationActivateIgnoringOtherApps = 1 << 1
        _target_app.activateWithOptions_(_NSApplicationActivateIgnoringOtherApps)
    except Exception:
        return False
    return True


# ---------------------------------------------------------------------------
# Login item / startup — LaunchAgent plist
# ---------------------------------------------------------------------------

def _launch_agent_path() -> str:
    override = os.environ.get("VOICE_TYPE_LAUNCH_AGENT_PATH")
    if override:
        return os.path.realpath(os.path.expanduser(override))
    agents_dir = os.path.expanduser("~/Library/LaunchAgents")
    return os.path.join(agents_dir, f"{_LAUNCH_AGENT_LABEL}.plist")


def _install_dir() -> str:
    configured = os.environ.get(
        "VOICE_TYPE_INSTALL_DIR",
        "~/Library/Application Support/Voice Type",
    )
    return os.path.realpath(os.path.expanduser(configured))


def _log_dir() -> str:
    configured = os.environ.get(
        "VOICE_TYPE_LOG_DIR",
        "~/Library/Logs/Voice Type",
    )
    return os.path.realpath(os.path.expanduser(configured))


def _launchd_domain() -> str:
    return f"gui/{os.getuid()}"


def _launchd_service(domain: str) -> str:
    return f"{domain}/{_LAUNCH_AGENT_LABEL}"


def startup_enabled(vbs_path: str = "") -> bool:
    return os.path.exists(_launch_agent_path())


def restart_supervisor_active() -> bool:
    # A loaded LaunchAgent does not prove that this particular process belongs
    # to it. Direct/manual launches are supported too, and launchd only sets
    # XPC_SERVICE_NAME on the process it started.
    return os.environ.get("XPC_SERVICE_NAME") == _LAUNCH_AGENT_LABEL


def set_startup(enable: bool, vbs_path: str = "",
                log: Callable[[str], None] | None = None) -> None:
    plist_path = _launch_agent_path()
    domain = _launchd_domain()
    service = _launchd_service(domain)
    if enable:
        install_dir = _install_dir()
        launcher_bin = os.path.join(install_dir, ".venv", "bin", "Voice Type")
        app_path = os.path.join(install_dir, "voice-type.py")
        launch_wrapper = os.path.join(install_dir, "launch-voice-type-mac.sh")
        log_path = os.path.join(_log_dir(), "launchd.log")
        if not os.path.exists(launcher_bin):
            setup_path = os.path.join(install_dir, "setup_mac.sh")
            message = (
                f"voice-type launcher missing at '{launcher_bin}'. "
                f"Run setup first from the repository: bash setup_mac.sh "
                f"(installed helper: {setup_path})"
            )
            if log:
                log(message)
            return
        if not os.path.isfile(app_path):
            message = (
                f"voice-type installed worker missing at '{app_path}'. "
                "Run setup again: bash setup_mac.sh"
            )
            if log:
                log(message)
            return
        if not os.access(launch_wrapper, os.X_OK):
            message = (
                f"voice-type launch wrapper missing at '{launch_wrapper}'. "
                "Run setup again: bash setup_mac.sh"
            )
            if log:
                log(message)
            return
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{_LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{launch_wrapper}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{install_dir}</string>
  <key>StandardOutPath</key>
  <string>{log_path}</string>
  <key>StandardErrorPath</key>
  <string>{log_path}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
</dict>
</plist>
"""
        os.makedirs(os.path.dirname(plist_path), exist_ok=True)
        with open(plist_path, "w", encoding="utf-8") as f:
            f.write(plist)
        subprocess.run(["launchctl", "bootout", service], check=False)
        subprocess.run(["launchctl", "bootstrap", domain, plist_path], check=False)
        subprocess.run(["launchctl", "kickstart", "-k", service], check=False)
        if log:
            log(f"Run on Startup enabled ({plist_path}).")
    else:
        subprocess.run(["launchctl", "bootout", service], check=False)
        if os.path.exists(plist_path):
            os.remove(plist_path)
        if log:
            log("Run on Startup disabled.")


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

def cuda_available() -> bool:
    """No CUDA on macOS; faster-whisper runs on CPU."""
    return False


def _apply_accessory_policy() -> None:
    """Set NSApplicationActivationPolicyAccessory (1).

    Safe to call multiple times — tkinter and pystray can each reset the
    policy back to Regular (0) when they call sharedApplication(), so we
    re-apply it at several points during startup.
    """
    try:
        from AppKit import NSApp
        NSApp.setActivationPolicy_(1)
    except Exception:
        pass


def setup_process() -> None:
    """Called before any GUI init — first chance to set the policy."""
    _apply_accessory_policy()
    _install_lifecycle_observers()


def apply_overlay_no_activate(root) -> None:
    """Prevent the overlay from holding key-window status on macOS.

    tkinter's Tk() init can reset NSApp's activation policy back to Regular,
    so we re-apply Accessory here (synchronously, after Tk is constructed)
    and again in a deferred callback once the run loop starts.
    """
    # Re-apply after tkinter may have reset it
    _apply_accessory_policy()

    def _resign_key():
        try:
            from AppKit import NSApp
            # Re-apply policy each time as pystray/tk can flip it back
            _apply_accessory_policy()
            for ns_win in NSApp.windows():
                if ns_win.isKeyWindow():
                    ns_win.resignKeyWindow()
        except Exception:
            pass

    root.after(100, _resign_key)

    # Re-resign after every deiconify (each time the overlay is shown)
    _orig_deiconify = root.deiconify
    def _patched_deiconify(*args, **kwargs):
        _orig_deiconify(*args, **kwargs)
        root.after(30, _resign_key)
    root.deiconify = _patched_deiconify


def open_log(path: str) -> None:
    subprocess.run(["open", path], check=False)


def activate_settings_window() -> None:
    """Bring the accessory app forward when its normal settings window opens."""
    try:
        from AppKit import NSApp
        NSApp.activateIgnoringOtherApps_(True)
    except Exception:
        pass


def get_foreground_window_title() -> str:
    try:
        from AppKit import NSWorkspace  # type: ignore[import]
        app = NSWorkspace.sharedWorkspace().activeApplication()
        return app.get("NSApplicationName", "unknown") if app else "unknown"
    except Exception:
        return "unknown"
