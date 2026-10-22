from __future__ import annotations

import objc
from overlay_feedback import checkmark_points
from AppKit import (
    NSApp,
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSFloatingWindowLevel,
    NSFont,
    NSLineBreakByTruncatingTail,
    NSLineBreakByWordWrapping,
    NSMakeRect,
    NSPanel,
    NSScreen,
    NSTextField,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)

_PANEL_WIDTH = 220
_TOP_ROW_HEIGHT = 26
_PREVIEW_HEIGHT = 36
_PADDING_X = 12
_PADDING_Y = 8
_ACCENT_WIDTH = 4
_DOT_SIZE = 12
_LABEL_WIDTH = 50
# Done and clipboard labels need more room; the panel itself never changes width.
_FEEDBACK_LABEL_WIDTH = 124
_BARS_WIDTH = 46
_BAR_W = 4
_BAR_GAP = 3
_BOTTOM_MARGIN = 20
_PANEL_HEIGHT = _TOP_ROW_HEIGHT + (_PADDING_Y * 2) + _PREVIEW_HEIGHT + 2


class _FlippedView(NSView):
    def isFlipped(self):
        return True


class _BarsView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(_BarsView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._bar_heights = [3.0] * 7
        self._check_progress = None
        self._bar_color = NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.27, 0.23, 1.0)
        return self

    def isFlipped(self):
        return True

    def setBarHeights_color_(self, bar_heights, color):
        self._bar_heights = list(bar_heights)
        self._bar_color = color
        self.setNeedsDisplay_(True)

    def setCheckProgress_(self, progress):
        self._check_progress = progress
        self.setNeedsDisplay_(True)

    def drawRect_(self, _rect):
        self._bar_color.set()
        if self._check_progress is not None:
            points = checkmark_points(self._check_progress)
            path = NSBezierPath.bezierPath()
            path.setLineWidth_(3.0)
            path.moveToPoint_(points[:2])
            path.lineToPoint_(points[2:4])
            path.lineToPoint_(points[4:])
            path.stroke()
            return
        bounds = self.bounds()
        max_y = bounds.size.height - 2
        for idx, height in enumerate(self._bar_heights):
            x = idx * (_BAR_W + _BAR_GAP)
            y = max_y - float(height)
            path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(x, y, _BAR_W, float(height)),
                1.5,
                1.5,
            )
            path.fill()


class AppKitOverlaySurface:
    def __init__(self):
        app = NSApplication.sharedApplication()
        app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

        style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        self._panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, _PANEL_WIDTH, _PANEL_HEIGHT),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self._panel.setLevel_(NSFloatingWindowLevel)
        self._panel.setOpaque_(False)
        self._panel.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.11, 0.96))
        self._panel.setHasShadow_(True)
        self._panel.setHidesOnDeactivate_(False)
        self._panel.setIgnoresMouseEvents_(True)
        self._panel.setReleasedWhenClosed_(False)
        self._panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
        )

        self._content = _FlippedView.alloc().initWithFrame_(NSMakeRect(0, 0, _PANEL_WIDTH, _PANEL_HEIGHT))
        self._panel.setContentView_(self._content)

        self._accent = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, _ACCENT_WIDTH, _PANEL_HEIGHT))
        self._accent.setWantsLayer_(True)
        self._content.addSubview_(self._accent)

        self._dot = NSTextField.alloc().initWithFrame_(NSMakeRect(12, 13, 14, 16))
        self._dot.setStringValue_("●")
        self._dot.setBezeled_(False)
        self._dot.setDrawsBackground_(False)
        self._dot.setEditable_(False)
        self._dot.setSelectable_(False)
        self._dot.setFont_(NSFont.systemFontOfSize_(11))
        self._content.addSubview_(self._dot)

        self._label = NSTextField.alloc().initWithFrame_(NSMakeRect(30, 11, _LABEL_WIDTH, 18))
        self._label.setStringValue_(" REC")
        self._label.setBezeled_(False)
        self._label.setDrawsBackground_(False)
        self._label.setEditable_(False)
        self._label.setSelectable_(False)
        self._label.setFont_(NSFont.boldSystemFontOfSize_(12))
        self._label.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.92, 1.0))
        self._label.cell().setLineBreakMode_(NSLineBreakByTruncatingTail)
        self._content.addSubview_(self._label)

        bars_x = _PANEL_WIDTH - _PADDING_X - _BARS_WIDTH
        self._bars = _BarsView.alloc().initWithFrame_(NSMakeRect(bars_x, 8, _BARS_WIDTH, 24))
        self._content.addSubview_(self._bars)

        self._preview = NSTextField.alloc().initWithFrame_(NSMakeRect(12, 36, _PANEL_WIDTH - 24, _PREVIEW_HEIGHT))
        self._preview.setStringValue_("")
        self._preview.setBezeled_(False)
        self._preview.setDrawsBackground_(False)
        self._preview.setEditable_(False)
        self._preview.setSelectable_(False)
        self._preview.setFont_(NSFont.systemFontOfSize_(12))
        self._preview.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.68, 1.0))
        preview_cell = self._preview.cell()
        preview_cell.setWraps_(True)
        preview_cell.setScrollable_(False)
        preview_cell.setLineBreakMode_(NSLineBreakByWordWrapping)
        if hasattr(preview_cell, "setUsesSingleLineMode_"):
            preview_cell.setUsesSingleLineMode_(False)
        if hasattr(preview_cell, "setMaximumNumberOfLines_"):
            preview_cell.setMaximumNumberOfLines_(2)
        self._content.addSubview_(self._preview)

        self._is_visible = False
        self._state = "rec"
        self._set_color(self._record_color())
        self._layout()

    def _record_color(self):
        return NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.27, 0.23, 1.0)

    def _processing_color(self):
        return NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.62, 0.04, 1.0)

    def _state_color(self):
        if self._state == "done":
            return NSColor.colorWithCalibratedRed_green_blue_alpha_(48 / 255, 209 / 255, 88 / 255, 1.0)
        return self._record_color() if self._state == "rec" else self._processing_color()

    def _set_color(self, color):
        self._accent.layer().setBackgroundColor_(color.CGColor())
        self._dot.setTextColor_(color)
        self._bars.setBarHeights_color_(self._bars._bar_heights, color)

    def _panel_height(self) -> float:
        return _PANEL_HEIGHT

    def _layout(self):
        width = _PANEL_WIDTH
        height = self._panel_height()
        self._panel.setContentSize_((width, height))
        self._content.setFrame_(NSMakeRect(0, 0, width, height))
        self._accent.setFrame_(NSMakeRect(0, 0, _ACCENT_WIDTH, height))
        self._dot.setFrame_(NSMakeRect(_PADDING_X, 13, 14, 16))
        label_width = _FEEDBACK_LABEL_WIDTH if self._state in ("done", "paste_failed") else _LABEL_WIDTH
        self._label.setFrame_(NSMakeRect(_PADDING_X + 18, 11, label_width, 18))
        bars_x = width - _PADDING_X - _BARS_WIDTH
        self._bars.setFrame_(NSMakeRect(bars_x, 8, _BARS_WIDTH, 24))
        self._preview.setFrame_(NSMakeRect(_PADDING_X, _TOP_ROW_HEIGHT + _PADDING_Y, width - (_PADDING_X * 2), _PREVIEW_HEIGHT))

    def set_state(self, state: str, preview: str):
        self._state = state
        label = {"rec": " REC", "done": preview,
                 "paste_failed": " Clipboard"}.get(state, " ...")
        self._label.setStringValue_(label)
        self._preview.setStringValue_("" if state == "done" else preview or "")
        self._bars.setCheckProgress_(0.0 if state == "done" else None)
        if state in ("done", "paste_failed"):
            self._bars._bar_heights = [3.0] * 7
        self._set_color(self._state_color())
        self._layout()

    def set_completion_progress(self, progress: float):
        self._bars.setCheckProgress_(progress)

    def set_alpha(self, alpha: float):
        self._panel.setAlphaValue_(alpha)

    def set_bar_heights(self, bar_heights):
        self._bars.setBarHeights_color_(bar_heights, self._state_color())

    def reposition(self, monitor: tuple[int, int, int, int]):
        left, _top, right, bottom = monitor
        screen = NSScreen.mainScreen()
        total_h = screen.frame().size.height
        width = _PANEL_WIDTH
        height = self._panel_height()
        x = left + (right - left) / 2 - width / 2
        y = total_h - bottom + _BOTTOM_MARGIN
        self._panel.setFrame_display_(NSMakeRect(x, y, width, height), True)

    def show(self, monitor: tuple[int, int, int, int]):
        self.reposition(monitor)
        self._panel.orderFrontRegardless()
        self._is_visible = True

    def hide(self):
        self._panel.orderOut_(None)
        self._is_visible = False

    def move_offscreen(self):
        self.hide()
