import Foundation

// Draw while dictating: the geometry half, ported from screen_marks.py. While the hotkey is
// held the mouse is a pen; each mark becomes an annotated screenshot and a numbered "[n]"
// in the text. Everything here is plain logic: what shape a stroke is, which window it
// belongs to, coordinate conversions, and where ink lands in a captured image.
//
// Coordinates are Quartz global points unless a name says otherwise: the origin is the
// top-left corner of the primary display, y grows downwards, and one unit is a point, not a
// pixel. A Retina capture has two pixels per point.

public struct MarkPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MarkRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: MarkPoint) -> Bool {
        x <= point.x && point.x < x + width && y <= point.y && point.y < y + height
    }

    public func intersects(_ other: MarkRect) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }

    public func union(_ other: MarkRect) -> MarkRect {
        let left = min(x, other.x), top = min(y, other.y)
        return MarkRect(left, top, max(x + width, other.x + other.width) - left, max(y + height, other.y + other.height) - top)
    }

    /// The smallest box holding every point, grown by `pad` on each side.
    static func around(_ points: [MarkPoint], pad: Double) -> MarkRect? {
        guard let first = points.first else { return nil }
        var (left, top, right, bottom) = (first.x, first.y, first.x, first.y)
        for p in points.dropFirst() {
            left = min(left, p.x)
            top = min(top, p.y)
            right = max(right, p.x)
            bottom = max(bottom, p.y)
        }
        return MarkRect(left - pad, top - pad, right - left + pad * 2, bottom - top + pad * 2)
    }
}

/// Unions two optional boxes, for redraw regions.
func unionOf(_ a: MarkRect?, _ b: MarkRect?) -> MarkRect? {
    guard let a else { return b }
    guard let b else { return a }
    return a.union(b)
}

public enum ScreenMarks {
    public static let maxMarks = 10
    /// Claude shrinks anything with a longer edge than this before the model sees it, so
    /// sending more pixels only makes the paste bigger.
    public static let maxImageEdge = 1568
    public static let screenshotRetentionDays = 7

    /// A click wobbles a few points; anything inside this is a point mark.
    public static let pointMarkMaxTravel = 6.0
    /// A drag counts as a straight arrow when it's long enough, nothing bulges far off the
    /// line between its ends, and it doesn't double back on itself. The path length ratio is
    /// loose because hand jitter adds length to any line.
    public static let arrowMinLength = 30.0
    public static let arrowMinStraightness = 0.75
    public static let arrowMaxBulgeRatio = 0.12
    public static let arrowMinBulge = 8.0

    /// Ink sizes in points; captures scale them by the image's pixels per point.
    public static let inkWidth = 4.0
    public static let ringRadius = 14.0
    public static let arrowheadLength = 20.0
    public static let badgeRadius = 11.0

    /// Half the size of the region captured around a mark on bare desktop.
    public static let desktopRegionHalf = 400.0
    /// Windows smaller than this are tooltips, cursors and the like.
    public static let minWindowEdge = 40.0

    // MARK: Stroke shape

    static func distance(_ a: MarkPoint, _ b: MarkPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }

    public static func pathLength(_ points: [MarkPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    static func distanceToLine(_ p: MarkPoint, _ a: MarkPoint, _ b: MarkPoint) -> Double {
        let length = distance(a, b)
        if length == 0 { return distance(p, a) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
    }

    public static func classify(_ points: [MarkPoint]) -> Stroke.Kind {
        guard let start = points.first else { return .point }
        if points.map({ distance(start, $0) }).max()! <= pointMarkMaxTravel { return .point }
        let end = points.last!
        let chord = distance(start, end)
        let length = pathLength(points)
        if chord < arrowMinLength || length == 0 { return .freeform }
        if chord / length < arrowMinStraightness { return .freeform }
        let bulge = points.map { distanceToLine($0, start, end) }.max()!
        if bulge > max(arrowMinBulge, chord * arrowMaxBulgeRatio) { return .freeform }
        return .arrow
    }

    /// (tip, left barb, right barb) for an arrow ending at the last point. The direction
    /// comes from a point about two head lengths back along the path rather than the last
    /// segment, since the final few mouse samples of a drag often wobble.
    public static func arrowhead(_ points: [MarkPoint], length: Double = arrowheadLength) -> (MarkPoint, MarkPoint, MarkPoint) {
        let tip = points.last!
        var base = points.first!
        for p in points.reversed() where distance(p, tip) >= length * 2 {
            base = p
            break
        }
        let angle = atan2(tip.y - base.y, tip.x - base.x)
        let spread = 28 * Double.pi / 180
        let left = MarkPoint(tip.x - length * cos(angle - spread), tip.y - length * sin(angle - spread))
        let right = MarkPoint(tip.x - length * cos(angle + spread), tip.y - length * sin(angle + spread))
        return (tip, left, right)
    }

    public static func bounds(_ points: [MarkPoint]) -> MarkRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return MarkRect(xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }

    /// The spot that decides which window a mark belongs to. An arrow points at its tip, so
    /// that's what matters. A click is its own point. A circle or scribble is about whatever
    /// it surrounds.
    public static func anchor(_ stroke: Stroke) -> MarkPoint {
        switch stroke.kind {
        case .point: return stroke.points[0]
        case .arrow: return stroke.points[stroke.points.count - 1]
        case .freeform:
            let b = bounds(stroke.points)
            return MarkPoint(b.x + b.width / 2, b.y + b.height / 2)
        }
    }

    /// Where the number badge sits, just clear of the mark itself.
    public static func badgeCenter(_ stroke: Stroke, radius: Double = badgeRadius) -> MarkPoint {
        let gap = radius * 1.4
        switch stroke.kind {
        case .point:
            let p = stroke.points[0]
            let offset = ringRadius + gap * 0.6
            return MarkPoint(p.x + offset, p.y - offset)
        case .arrow:
            // Behind the tail, so it never covers what the arrow points at.
            let start = stroke.points[0], end = stroke.points[stroke.points.count - 1]
            let length = distance(start, end) == 0 ? 1.0 : distance(start, end)
            let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
            return MarkPoint(start.x - ux * gap, start.y - uy * gap)
        case .freeform:
            let b = bounds(stroke.points)
            return MarkPoint(b.x - gap * 0.7, b.y - gap * 0.7)
        }
    }

    // MARK: Windows and displays

    /// The frontmost normal window under `point`. `windows` is CGWindowListCopyWindowInfo's
    /// list, which is ordered front to back. Layer 0 is where normal app windows live;
    /// menus, the Dock and status items sit on other layers. Our own windows (the pill and
    /// the ink) are skipped by process id.
    public static func chooseWindow(_ windows: [WindowInfo], at point: MarkPoint, excluding pids: Set<Int32> = []) -> WindowInfo? {
        windows.first { window in
            window.layer == 0 && window.alpha > 0 && !pids.contains(window.ownerPID)
                && window.bounds.width >= minWindowEdge && window.bounds.height >= minWindowEdge
                && window.bounds.contains(point)
        }
    }

    /// The display under `point`, or the nearest one if it's off every display.
    public static func display(containing point: MarkPoint, in displays: [MarkRect]) -> MarkRect? {
        if let display = displays.first(where: { $0.contains(point) }) { return display }
        func gap(_ d: MarkRect) -> Double {
            hypot(max(d.x - point.x, 0, point.x - (d.x + d.width)), max(d.y - point.y, 0, point.y - (d.y + d.height)))
        }
        // min(by:) keeps the first of equals, like Python's min().
        return displays.min { gap($0) < gap($1) }
    }

    /// A generous box around `point`, slid to stay inside its display.
    public static func desktopRegion(_ display: MarkRect, around point: MarkPoint, half: Double = desktopRegionHalf) -> MarkRect {
        let w = min(half * 2, display.width), h = min(half * 2, display.height)
        let x = min(max(point.x - w / 2, display.x), display.x + display.width - w)
        let y = min(max(point.y - h / 2, display.y), display.y + display.height - h)
        return MarkRect(x, y, w, h)
    }

    /// An AppKit screen or window frame in Quartz global coordinates. AppKit puts the origin
    /// at the bottom-left of the primary display with y growing upwards; Quartz puts it at
    /// the top-left with y growing down. Both flip around the primary display's height, even
    /// for frames on other displays.
    public static func appKitFrameToQuartz(_ frame: MarkRect, primaryHeight: Double) -> MarkRect {
        MarkRect(frame.x, primaryHeight - frame.y - frame.height, frame.width, frame.height)
    }

    /// A Quartz global point in a flipped view covering `screen`.
    public static func quartzToView(_ point: MarkPoint, screen: MarkRect) -> MarkPoint {
        MarkPoint(point.x - screen.x, point.y - screen.y)
    }

    /// A Quartz global point in pixel coordinates of a captured image. The scale comes from
    /// the image itself rather than the display's backing factor, so 1x displays, Retina
    /// displays and a window straddling both all come out right.
    public static func toImage(_ point: MarkPoint, capture rect: MarkRect, imageWidth: Int, imageHeight: Int) -> MarkPoint {
        let sx = rect.width != 0 ? Double(imageWidth) / rect.width : 1
        let sy = rect.height != 0 ? Double(imageHeight) / rect.height : 1
        return MarkPoint((point.x - rect.x) * sx, (point.y - rect.y) * sy)
    }

    /// Python's round(): halves go to the even neighbour.
    static func pythonRound(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }

    public static func fitLongEdge(width: Int, height: Int, maxEdge: Int = maxImageEdge) -> (Int, Int) {
        let longest = max(width, height)
        guard longest > maxEdge else { return (width, height) }
        let scale = Double(maxEdge) / Double(longest)
        return (max(1, pythonRound(Double(width) * scale)), max(1, pythonRound(Double(height) * scale)))
    }

    /// Lays out one mark's ink, mapping points through `transform`. `scale` is pixels per
    /// point, so ink and badges keep the same apparent size on Retina captures as on screen.
    public static func inkShapes(_ stroke: Stroke, scale: Double = 1, transform: (MarkPoint) -> MarkPoint = { $0 }) -> InkShapes {
        var line = stroke.points.map(transform)
        var head: (MarkPoint, MarkPoint, MarkPoint)?
        var ring: (center: MarkPoint, radius: Double)?
        if stroke.kind == .arrow {
            let (tip, left, right) = arrowhead(stroke.points)
            head = (transform(tip), transform(left), transform(right))
            // Stop the line at the head's base, or its round cap pokes out past the tip.
            let base = MarkPoint((left.x + right.x) / 2, (left.y + right.y) / 2)
            line = Array(line.dropLast()) + [transform(base)]
        }
        if stroke.kind == .point {
            ring = (transform(stroke.points[0]), ringRadius * scale)
            line = []
        }
        return InkShapes(kind: stroke.kind, line: line, arrowhead: head, ring: ring,
                         badge: (transform(badgeCenter(stroke)), badgeRadius * scale), width: inkWidth * scale, number: stroke.number)
    }
}

/// One mouse-down to mouse-up, in Quartz global points. Times are on the app's monotonic
/// clock (system uptime), like the controller's.
public struct Stroke: Sendable {
    public enum Kind: String, Sendable { case point, arrow, freeform }

    public var points: [MarkPoint]
    public var startedAt: Double
    public var endedAt: Double
    public var number: Int
    public var kind: Kind

    public init(points: [MarkPoint], startedAt: Double, endedAt: Double, number: Int = 0, kind: Kind? = nil) {
        self.points = points
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.number = number
        self.kind = kind ?? ScreenMarks.classify(points)
    }
}

/// Everything to draw for one mark, already in the target's coordinates.
public struct InkShapes {
    public var kind: Stroke.Kind
    public var line: [MarkPoint]
    public var arrowhead: (MarkPoint, MarkPoint, MarkPoint)?
    public var ring: (center: MarkPoint, radius: Double)?
    public var badge: (center: MarkPoint, radius: Double)
    public var width: Double
    public var number: Int
}

/// One on-screen window, from CGWindowListCopyWindowInfo.
public struct WindowInfo: Equatable, Sendable {
    public var number: Int
    public var ownerPID: Int32
    public var ownerName: String?
    public var layer: Int
    public var alpha: Double
    public var bounds: MarkRect

    public init(number: Int, ownerPID: Int32, ownerName: String? = nil, layer: Int = 0, alpha: Double = 1, bounds: MarkRect) {
        self.number = number
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}
