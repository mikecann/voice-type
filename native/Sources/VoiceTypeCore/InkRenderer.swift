import CoreGraphics
import CoreText
import Foundation

/// Draws marks with Core Graphics, for both the live ink on screen and the ink composited
/// onto screenshots. The two differ only in their `Style`, as appkit_ink.py and
/// mark_capture.py's Pillow drawing did.
public enum InkRenderer {
    /// (255, 59, 48), the red Python drew with.
    public static let inkRGB: (UInt8, UInt8, UInt8) = (255, 59, 48)

    public struct Style: Sendable {
        /// Pillow lines are whole pixels wide, so the screenshot rounds the width.
        public var roundsLineWidth: Bool
        /// The badge's white outline, from its radius.
        public var badgeOutlineWidth: @Sendable (Double) -> Double
        /// The number's font size, from the badge's radius.
        public var fontSize: @Sendable (Double) -> Double
        public var boldNumber: Bool
        /// Pillow's shapes fill the pixels from their coordinates rightwards and downwards,
        /// which in Core Graphics' terms is half a pixel further on.
        public var pixelOffset: Double
        /// Pillow's ellipse boxes include their last pixel, so its circles are half a pixel
        /// bigger.
        public var radiusGrowth: Double
        /// Pillow draws an ellipse's outline inside its box; NSBezierPath straddles it.
        public var outlinesInside: Bool
        /// Pillow wrote the ink's values straight into the capture's pixels, so the
        /// screenshot gives its colours in the context's own space. On screen they're
        /// calibrated (generic) RGB, as appkit_ink.py's NSColor was.
        public var rawColors: Bool

        /// mark_capture.py's Pillow drawing.
        public static let screenshot = Style(
            roundsLineWidth: true,
            badgeOutlineWidth: { max(1, Double(ScreenMarks.pythonRound($0 / 6))) },
            fontSize: { Double(max(8, ScreenMarks.pythonRound($0 * 1.25))) },
            boldNumber: false, pixelOffset: 0.5, radiusGrowth: 0.5, outlinesInside: true, rawColors: true
        )

        /// appkit_ink.py's live ink.
        public static let screen = Style(
            roundsLineWidth: false, badgeOutlineWidth: { _ in 1.5 }, fontSize: { $0 * 1.2 },
            boldNumber: true, pixelOffset: 0, radiusGrowth: 0, outlinesInside: false, rawColors: false
        )
    }

    static func color(_ components: [CGFloat], in context: CGContext, style: Style) -> CGColor {
        if style.rawColors, let space = context.colorSpace, space.model == .rgb,
           let color = CGColor(colorSpace: space, components: components + [1]) {
            return color
        }
        return CGColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
    }

    static func inkColor(_ context: CGContext, _ style: Style) -> CGColor { color([1, 59.0 / 255, 48.0 / 255], in: context, style: style) }
    static func white(_ context: CGContext, _ style: Style) -> CGColor { color([1, 1, 1], in: context, style: style) }

    /// Draws every mark's ink first and the badges on top, so a later mark's line never
    /// covers an earlier mark's number. `context` must have y growing downwards.
    public static func draw(_ marks: [InkShapes], in context: CGContext, style: Style) {
        context.saveGState()
        context.translateBy(x: style.pixelOffset, y: style.pixelOffset)
        for shapes in marks { drawInk(shapes, in: context, style: style) }
        for shapes in marks { drawBadge(shapes, in: context, style: style) }
        context.restoreGState()
    }

    /// The stroke still being drawn, as a plain line.
    public static func drawLine(_ points: [MarkPoint], width: Double, in context: CGContext, style: Style = .screen) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(inkColor(context, style))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
        context.strokePath()
        context.restoreGState()
    }

    static func lineWidth(_ shapes: InkShapes, _ style: Style) -> Double {
        style.roundsLineWidth ? Double(max(1, ScreenMarks.pythonRound(shapes.width))) : shapes.width
    }

    private static func drawInk(_ shapes: InkShapes, in context: CGContext, style: Style) {
        let width = lineWidth(shapes, style)
        drawLine(shapes.line, width: width, in: context, style: style)
        if let (tip, left, right) = shapes.arrowhead {
            context.setFillColor(inkColor(context, style))
            context.addLines(between: [tip, left, right].map { CGPoint(x: $0.x, y: $0.y) })
            context.closePath()
            context.fillPath()
        }
        if let ring = shapes.ring {
            let r = ring.radius + style.radiusGrowth - (style.outlinesInside ? width / 2 : 0)
            context.setStrokeColor(inkColor(context, style))
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: ring.center.x - r, y: ring.center.y - r, width: r * 2, height: r * 2))
        }
    }

    private static func drawBadge(_ shapes: InkShapes, in context: CGContext, style: Style) {
        let (center, radius) = shapes.badge
        let r = radius + style.radiusGrowth
        let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let outline = style.badgeOutlineWidth(radius)
        if style.outlinesInside {
            // A white disc with the red one inside it, rather than a stroke over a fill,
            // which would leave a faint red fringe outside the white.
            context.setFillColor(white(context, style))
            context.fillEllipse(in: circle)
            context.setFillColor(inkColor(context, style))
            context.fillEllipse(in: circle.insetBy(dx: outline, dy: outline))
        } else {
            context.setFillColor(inkColor(context, style))
            context.fillEllipse(in: circle)
            context.setStrokeColor(white(context, style))
            context.setLineWidth(outline)
            context.strokeEllipse(in: circle)
        }

        let font = CTFontCreateUIFontForLanguage(style.boldNumber ? .emphasizedSystem : .system, style.fontSize(radius), nil)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white(context, style),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(shapes.number), attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.saveGState()
        // y grows downwards here, so the glyphs need flipping back up. Centred between the
        // font's ascender and descender, as Pillow's "mm" anchor does.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - advance / 2, y: center.y + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// What one display's live ink panel shows, in that panel's view coordinates (y down from
/// its top-left), and what changed since the last frame, so the overlay only redraws the part
/// of the one display where the ink moved rather than every full-screen panel at 60 fps.
public struct InkLayerContent {
    /// The finished marks that reach this display.
    public private(set) var marks: [InkShapes] = []
    /// The mark being drawn, if it reaches this display.
    public private(set) var line: [MarkPoint]?
    private var marksBounds: MarkRect?
    private var lineBounds: MarkRect?
    /// What was drawn, to tell when nothing on this display changed.
    private var marksKey: [Double] = []
    private var lineKey: [Double] = []

    public init() {}

    /// `screen` is the display in Quartz global points.
    public init(strokes: [Stroke], current: [MarkPoint]?, screen: MarkRect) {
        let view = MarkRect(0, 0, screen.width, screen.height)
        let toView: (MarkPoint) -> MarkPoint = { ScreenMarks.quartzToView($0, screen: screen) }
        for stroke in strokes {
            let shapes = ScreenMarks.inkShapes(stroke, transform: toView)
            let bounds = Self.bounds(shapes)
            guard bounds.intersects(view) else { continue }
            marks.append(shapes)
            marksBounds = unionOf(marksBounds, bounds)
            // Mark numbers start again each dictation, so the key has the mark's end time too.
            marksKey += [Double(stroke.number), stroke.endedAt, Double(stroke.points.count)]
        }
        if let current, current.count > 1 {
            let points = current.map(toView)
            if let bounds = MarkRect.around(points, pad: ScreenMarks.inkWidth / 2 + Self.antialiasPad), bounds.intersects(view) {
                line = points
                lineBounds = bounds
                lineKey = [Double(points.count), points[0].x, points[0].y, points[points.count - 1].x, points[points.count - 1].y]
            }
        }
    }

    public var isEmpty: Bool { marks.isEmpty && line == nil }

    /// The part of the view to redraw to go from `old` to this, or nil if nothing on this
    /// display changed: the old and new boxes of whichever of the marks and the line moved.
    public func dirtyRect(since old: InkLayerContent) -> MarkRect? {
        var dirty: MarkRect?
        if marksKey != old.marksKey { dirty = unionOf(dirty, unionOf(old.marksBounds, marksBounds)) }
        if lineKey != old.lineKey { dirty = unionOf(dirty, unionOf(old.lineBounds, lineBounds)) }
        return dirty
    }

    /// Room for Core Graphics' antialiasing past the geometry.
    static let antialiasPad = 2.0

    /// Covers everything InkRenderer.draw puts down for one mark: the line with its round
    /// caps, the arrowhead, the ring and the badge with its outline and number.
    static func bounds(_ shapes: InkShapes) -> MarkRect {
        let pad = shapes.width / 2 + antialiasPad
        var points = shapes.line
        if let (tip, left, right) = shapes.arrowhead { points += [tip, left, right] }
        var box = MarkRect.around(points, pad: pad)
        if let ring = shapes.ring {
            box = unionOf(box, MarkRect.around([ring.center], pad: ring.radius + pad))
        }
        // The badge's white outline straddles its edge (1.5 pt on screen); its number sits
        // inside it.
        let badge = MarkRect.around([shapes.badge.center], pad: shapes.badge.radius + 1 + antialiasPad)!
        return unionOf(box, badge)!
    }
}
