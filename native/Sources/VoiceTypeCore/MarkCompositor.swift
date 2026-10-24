import CoreGraphics
import Foundation
import ImageIO
import VoiceTypeImaging

/// Draws marks onto one capture and makes a small PNG of it, ported from composite_png in
/// mark_capture.py: ink at the capture's own resolution, then a 1568 px long edge (Claude
/// shrinks anything bigger anyway), 256 colours with no dithering so text stays crisp, alpha
/// snapped so a window's body stays opaque, and an optimised PNG. A typical window goes from
/// about 1 MB to 100 to 180 KB.
///
/// Pixel values are kept as they were captured, in the capture's own colour space, and its
/// ICC profile goes into the PNG, as Pillow did; the ink's red is written as raw values in
/// that space too. Core Graphics antialiases the ink, where Pillow's lines were jagged.
public enum MarkCompositor {
    public static func compositePNG(_ png: Data, captureRect: MarkRect, strokes: [Stroke], maxEdge: Int = ScreenMarks.maxImageEdge) throws -> Data {
        var image = try decode(png)
        let scale = captureRect.width != 0 ? Double(image.width) / captureRect.width : 1
        let (w, h) = (image.width, image.height)
        let shapes = strokes.sorted { $0.number < $1.number }.map { stroke in
            ScreenMarks.inkShapes(stroke, scale: scale) { ScreenMarks.toImage($0, capture: captureRect, imageWidth: w, imageHeight: h) }
        }
        drawInk(shapes, onto: &image)
        let (fw, fh) = ScreenMarks.fitLongEdge(width: image.width, height: image.height, maxEdge: maxEdge)
        image = PillowImaging.resizeLanczos(image, width: fw, height: fh)
        var (palette, indices) = PillowImaging.quantizeOctree(image)
        snapAlpha(&palette)
        return try PNGWriter.palettePNG(width: image.width, height: image.height, palette: palette, indices: indices,
                                        iccProfile: PNGWriter.iccProfile(in: png))
    }

    /// Makes a quantized window opaque again. The octree averages every colour in a bucket,
    /// alpha included, so the body of a window can come out at 254 when some of its
    /// antialiased corner pixels land in the same bucket. Anything within 16 levels of opaque
    /// or clear is snapped back; on a corner's edge nobody can see it.
    static func snapAlpha(_ palette: inout [UInt8]) {
        for i in stride(from: 3, to: palette.count, by: 4) {
            if palette[i] >= 240 { palette[i] = 255 } else if palette[i] < 16 { palette[i] = 0 }
        }
    }

    // MARK: Decoding

    struct DecodeError: LocalizedError {
        var errorDescription: String? { "the capture isn't a readable image" }
    }

    /// The capture as straight RGBA bytes, without any colour conversion, which is what
    /// Pillow's `Image.open(...).convert("RGBA")` gives.
    static func decode(_ data: Data) throws -> RGBAImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DecodeError()
        }
        if let direct = readDirectly(image) { return direct }
        // Anything unusual (16-bit, grey, a palette): let Core Graphics draw it into RGBA.
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw DecodeError() }
        PillowImaging.unpremultiply(&pixels)
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    /// The decoded bytes as they are, for the 8-bit RGB layouts PNGs decode to.
    static func readDirectly(_ image: CGImage) -> RGBAImage? {
        guard image.bitsPerComponent == 8, image.colorSpace?.model == .rgb, let data = image.dataProvider?.data as Data? else { return nil }
        let w = image.width, h = image.height, rowBytes = image.bytesPerRow
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let littleEndian = order == .byteOrder32Little
        guard order == [] || order == .byteOrder32Big || littleEndian else { return nil }
        let alpha = image.alphaInfo
        let bpp = image.bitsPerPixel / 8
        guard (bpp == 4 && alpha != .none && alpha != .alphaOnly) || (bpp == 3 && alpha == .none && !littleEndian) else { return nil }
        guard data.count >= rowBytes * (h - 1) + w * bpp else { return nil }
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeBytes { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                PixelLoops.copyPixels(src, dst, width: w, height: h, rowBytes: rowBytes, bytesPerPixel: bpp, littleEndian: littleEndian,
                           alphaFirst: alphaFirst, opaque: opaque)
            }
        }
        if premultiplied { PillowImaging.unpremultiply(&pixels) }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    // MARK: Ink

    /// Draws the marks into a transparent layer just big enough for them, then lays it over
    /// the capture. Pixels away from the ink keep their exact values.
    static func drawInk(_ shapes: [InkShapes], onto image: inout RGBAImage) {
        guard !shapes.isEmpty, let bounds = inkBounds(shapes, width: image.width, height: image.height) else { return }
        let (lx, ly, lw, lh) = bounds
        var layer = [UInt8](repeating: 0, count: lw * lh * 4)
        let drawn = layer.withUnsafeMutableBytes { buffer -> Bool in
            // Device RGB, so the ink's components go in as raw values with no conversion.
            guard let context = CGContext(data: buffer.baseAddress, width: lw, height: lh, bitsPerComponent: 8, bytesPerRow: lw * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Image pixel coordinates, y down, with the layer's corner at (lx, ly).
            context.translateBy(x: 0, y: CGFloat(lh))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: CGFloat(-lx), y: CGFloat(-ly))
            InkRenderer.draw(shapes, in: context, style: .screenshot)
            return true
        }
        guard drawn else { return }
        let width = image.width
        layer.withUnsafeBufferPointer { src in
            image.pixels.withUnsafeMutableBufferPointer { dst in
                PixelLoops.layOver(src, layerX: lx, layerY: ly, layerWidth: lw, layerHeight: lh, onto: dst, width: width)
            }
        }
    }

    /// The pixels the marks can touch, with a margin for line caps and antialiasing, clipped
    /// to the image.
    static func inkBounds(_ shapes: [InkShapes], width: Int, height: Int) -> (Int, Int, Int, Int)? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: MarkPoint, _ pad: Double) {
            minX = min(minX, p.x - pad)
            minY = min(minY, p.y - pad)
            maxX = max(maxX, p.x + pad)
            maxY = max(maxY, p.y + pad)
        }
        for s in shapes {
            let pad = s.width + 3
            s.line.forEach { add($0, pad) }
            if let (a, b, c) = s.arrowhead { [a, b, c].forEach { add($0, pad) } }
            if let ring = s.ring { add(ring.center, ring.radius + pad) }
            add(s.badge.center, s.badge.radius + 3)
        }
        let x0 = max(0, Int(floor(minX))), y0 = max(0, Int(floor(minY)))
        let x1 = min(width, Int(ceil(maxX)) + 1), y1 = min(height, Int(ceil(maxY)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }
}
