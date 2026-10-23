"""Live ink for drawing while dictating (macOS).

One transparent, click-through panel per display, above normal windows. The
panels never become key or main and the app stays an accessory, so the
frontmost app (where the paste goes) never changes. Main thread only.
"""

from __future__ import annotations

import objc
from AppKit import (
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSMakeRect,
    NSPanel,
    NSPopUpMenuWindowLevel,
    NSScreen,
    NSString,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)

from screen_marks import INK_WIDTH, appkit_frame_to_quartz, ink_shapes, quartz_to_view

# NSWindowSharingNone keeps the ink out of desktop-region captures.
_NS_WINDOW_SHARING_NONE = 0


def _ink_color():
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 59 / 255, 48 / 255, 1.0)


class _InkView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(_InkView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._screen_rect = (0.0, 0.0, 0.0, 0.0)
        self._strokes = []
        self._current = None
        return self

    def isFlipped(self):
        # Top-left origin, like Quartz global coordinates.
        return True

    def hitTest_(self, _point):
        return None

    def _to_view(self, point):
        return quartz_to_view(point, self._screen_rect)

    def drawRect_(self, _rect):
        color = _ink_color()
        for stroke in self._strokes:
            self._draw_shapes(ink_shapes(stroke, transform=self._to_view), color)
        if self._current and len(self._current) > 1:
            color.set()
            path = self._polyline([self._to_view(p) for p in self._current])
            path.setLineWidth_(INK_WIDTH)
            path.stroke()

    @staticmethod
    def _polyline(points):
        path = NSBezierPath.bezierPath()
        path.setLineCapStyle_(1)   # round
        path.setLineJoinStyle_(1)  # round
        path.moveToPoint_(points[0])
        for point in points[1:]:
            path.lineToPoint_(point)
        return path

    def _draw_shapes(self, shapes, color):
        color.set()
        if len(shapes.line) > 1:
            path = self._polyline(shapes.line)
            path.setLineWidth_(shapes.width)
            path.stroke()
        if shapes.arrowhead is not None:
            head = NSBezierPath.bezierPath()
            head.moveToPoint_(shapes.arrowhead[0])
            head.lineToPoint_(shapes.arrowhead[1])
            head.lineToPoint_(shapes.arrowhead[2])
            head.closePath()
            head.fill()
        if shapes.ring is not None:
            (cx, cy), r = shapes.ring
            ring = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(cx - r, cy - r, r * 2, r * 2))
            ring.setLineWidth_(shapes.width)
            ring.stroke()
        (bx, by), br = shapes.badge
        badge = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(bx - br, by - br, br * 2, br * 2))
        badge.fill()
        NSColor.whiteColor().set()
        badge.setLineWidth_(1.5)
        badge.stroke()
        label = NSString.stringWithString_(str(shapes.number))
        attributes = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(br * 1.2),
            NSForegroundColorAttributeName: NSColor.whiteColor(),
        }
        size = label.sizeWithAttributes_(attributes)
        label.drawAtPoint_withAttributes_(
            (bx - size.width / 2, by - size.height / 2), attributes,
        )


class AppKitInkOverlay:
    def __init__(self):
        self._panels: list[tuple[object, object]] = []
        self._frames: list = []
        self._visible = False

    def _screen_frames(self):
        return [
            (f.origin.x, f.origin.y, f.size.width, f.size.height)
            for f in (screen.frame() for screen in NSScreen.screens())
        ]

    def _ensure_panels(self) -> None:
        frames = self._screen_frames()
        if frames == self._frames and self._panels:
            return
        for panel, _view in self._panels:
            panel.orderOut_(None)
        self._panels = []
        self._frames = frames
        if not frames:
            return
        # Quartz flips around the primary display's height (screens()[0]).
        primary_height = frames[0][3]
        for frame in frames:
            panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
                NSMakeRect(*frame),
                NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
                NSBackingStoreBuffered,
                False,
            )
            panel.setLevel_(NSPopUpMenuWindowLevel)
            panel.setOpaque_(False)
            panel.setBackgroundColor_(NSColor.clearColor())
            panel.setHasShadow_(False)
            panel.setIgnoresMouseEvents_(True)
            panel.setHidesOnDeactivate_(False)
            panel.setReleasedWhenClosed_(False)
            panel.setSharingType_(_NS_WINDOW_SHARING_NONE)
            panel.setCollectionBehavior_(
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary
                | NSWindowCollectionBehaviorStationary
                | NSWindowCollectionBehaviorIgnoresCycle
            )
            view = _InkView.alloc().initWithFrame_(NSMakeRect(0, 0, frame[2], frame[3]))
            # Plain attribute assignment, not an Objective-C setter, so the
            # Python objects aren't bridged through NSArray on every frame.
            view._screen_rect = appkit_frame_to_quartz(frame, primary_height)
            panel.setContentView_(view)
            self._panels.append((panel, view))

    def show(self, strokes, current) -> None:
        if not self._visible:
            self._ensure_panels()
        for panel, view in self._panels:
            view._strokes = strokes
            view._current = current
            view.setNeedsDisplay_(True)
            if not self._visible:
                panel.orderFrontRegardless()
        self._visible = True

    def clear(self) -> None:
        if not self._visible:
            return
        for panel, view in self._panels:
            view._strokes = []
            view._current = None
            panel.orderOut_(None)
        self._visible = False
