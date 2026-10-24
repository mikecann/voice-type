import Darwin
import Foundation

/// An 8-bit RGBA image with straight (not premultiplied) alpha, as Pillow's "RGBA" mode
/// holds it.
public struct RGBAImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// The parts of Pillow that mark_capture.py's composite_png used, ported so native
/// screenshots come out the way Python's did: `resize(..., LANCZOS)` on RGBA (premultiplied
/// while it filters) and `quantize(256, FASTOCTREE, dither=NONE)`. Both are integer code in
/// Pillow, so the ports give the same bytes for the same input. Pillow's licence (MIT-CMU)
/// and QuantOctree.c's (MIT, Oliver Tonnhofer) allow it; libimagequant, which is GPL, isn't
/// used.
public enum PillowImaging {
    // MARK: Premultiplying (Convert.c)

    /// RGBA -> RGBa: MULDIV255, rounding as Pillow does.
    public static func premultiply(_ pixels: inout [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { premultiply($0) }
    }

    static func premultiply(_ p: UnsafeMutableBufferPointer<UInt8>) {
        var i = 0
        while i < p.count {
            let alpha = UInt32(p[i + 3])
            for c in 0..<3 {
                let tmp = UInt32(p[i + c]) * alpha + 128
                p[i + c] = UInt8(((tmp >> 8) + tmp) >> 8)
            }
            i += 4
        }
    }

    /// RGBa -> RGBA.
    public static func unpremultiply(_ pixels: inout [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { unpremultiply($0) }
    }

    static func unpremultiply(_ p: UnsafeMutableBufferPointer<UInt8>) {
        var i = 0
        while i < p.count {
            let alpha = Int(p[i + 3])
            if alpha != 255 && alpha != 0 {
                for c in 0..<3 { p[i + c] = UInt8(min(255, (255 * Int(p[i + c])) / alpha)) }
            }
            i += 4
        }
    }

    // MARK: Resampling (Resample.c)

    static let precisionBits: Int32 = 32 - 8 - 2

    static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let px = x * Double.pi
        return sin(px) / px
    }

    static func lanczos(_ x: Double) -> Double {
        -3.0 <= x && x < 3.0 ? sinc(x) * sinc(x / 3) : 0
    }

    /// precompute_coeffs and normalize_coeffs_8bpc for the LANCZOS filter (support 3).
    static func coefficients(inSize: Int, outSize: Int) -> (ksize: Int, bounds: [Int], kk: [Int32]) {
        let in0: Float = 0, in1 = Float(inSize)
        let scale = Double(in1 - in0) / Double(outSize)
        let filterscale = max(scale, 1.0)
        let support = 3.0 * filterscale
        let ksize = Int(ceil(support)) * 2 + 1
        var bounds = [Int](repeating: 0, count: outSize * 2)
        var kk = [Int32](repeating: 0, count: outSize * ksize)
        var k = [Double](repeating: 0, count: ksize)
        let invFilterscale = 1.0 / filterscale
        for xx in 0..<outSize {
            let center = Double(in0) + (Double(xx) + 0.5) * scale
            var ww = 0.0
            // C's (int) truncates towards zero.
            let xmin = max(0, Int(center - support + 0.5))
            let xmax = min(inSize, Int(center + support + 0.5)) - xmin
            for x in 0..<ksize { k[x] = 0 }
            for x in 0..<max(0, xmax) {
                let w = lanczos((Double(x + xmin) - center + 0.5) * invFilterscale)
                k[x] = w
                ww += w
            }
            if ww != 0 {
                for x in 0..<max(0, xmax) { k[x] /= ww }
            }
            for x in 0..<ksize {
                let v = k[x] * Double(1 << precisionBits)
                kk[xx * ksize + x] = Int32(v < 0 ? -0.5 + v : 0.5 + v)
            }
            bounds[xx * 2] = xmin
            bounds[xx * 2 + 1] = xmax
        }
        return (ksize, bounds, kk)
    }

    @inline(__always)
    static func clip8(_ ss: Int32) -> UInt8 {
        let v = ss >> precisionBits
        return v < 0 ? 0 : v > 255 ? 255 : UInt8(v)
    }

    /// Image.resize(size, Image.LANCZOS) on an RGBA image: premultiplied, two passes
    /// (horizontal, then vertical), 22-bit fixed point, then back to straight alpha.
    public static func resizeLanczos(_ image: RGBAImage, width outW: Int, height outH: Int) -> RGBAImage {
        if outW == image.width && outH == image.height { return image }
        var current = image.pixels
        premultiply(&current)
        let inW = image.width, inH = image.height
        let vertical = coefficients(inSize: inH, outSize: outH)
        var verticalBounds = vertical.bounds
        if outW != inW {
            // Only the rows the vertical pass will read.
            let yFirst = vertical.bounds[0]
            let yLast = vertical.bounds[outH * 2 - 2] + vertical.bounds[outH * 2 - 1]
            for i in 0..<outH { verticalBounds[i * 2] -= yFirst }
            let horizontal = coefficients(inSize: inW, outSize: outW)
            var temp = [UInt8](repeating: 0, count: outW * (yLast - yFirst) * 4)
            current.withUnsafeBufferPointer { src in
                temp.withUnsafeMutableBufferPointer { dst in
                    horizontal.kk.withUnsafeBufferPointer { kk in
                        horizontal.bounds.withUnsafeBufferPointer { bounds in
                            horizontalPass(src, inWidth: inW, firstRow: yFirst, dst, outWidth: outW, rows: yLast - yFirst,
                                           ksize: horizontal.ksize, bounds: bounds, kk: kk)
                        }
                    }
                }
            }
            current = temp
        }
        let width = outW
        if outH != inH {
            var output = [UInt8](repeating: 0, count: width * outH * 4)
            current.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    vertical.kk.withUnsafeBufferPointer { kk in
                        verticalBounds.withUnsafeBufferPointer { bounds in
                            verticalPass(src, dst, width: width, outHeight: outH, ksize: vertical.ksize, bounds: bounds, kk: kk)
                        }
                    }
                }
            }
            current = output
        }
        unpremultiply(&current)
        return RGBAImage(width: width, height: outH, pixels: current)
    }

    /// _ImagingResampleHorizontal_8bpc for four bands.
    static func horizontalPass(_ src: UnsafeBufferPointer<UInt8>, inWidth: Int, firstRow: Int, _ dst: UnsafeMutableBufferPointer<UInt8>,
                               outWidth: Int, rows: Int, ksize: Int, bounds: UnsafeBufferPointer<Int>, kk: UnsafeBufferPointer<Int32>) {
        for yy in 0..<rows {
            let lineIn = (yy + firstRow) * inWidth * 4
            let lineOut = yy * outWidth * 4
            for xx in 0..<outWidth {
                let xmin = bounds[xx * 2], xmax = bounds[xx * 2 + 1]
                let k = xx * ksize
                var s0: Int32 = 1 << (precisionBits - 1), s1 = s0, s2 = s0, s3 = s0
                var p = lineIn + xmin * 4
                for x in 0..<xmax {
                    let c = kk[k + x]
                    s0 &+= Int32(src[p]) &* c
                    s1 &+= Int32(src[p + 1]) &* c
                    s2 &+= Int32(src[p + 2]) &* c
                    s3 &+= Int32(src[p + 3]) &* c
                    p += 4
                }
                let o = lineOut + xx * 4
                dst[o] = clip8(s0)
                dst[o + 1] = clip8(s1)
                dst[o + 2] = clip8(s2)
                dst[o + 3] = clip8(s3)
            }
        }
    }

    /// _ImagingResampleVertical_8bpc for four bands.
    static func verticalPass(_ src: UnsafeBufferPointer<UInt8>, _ dst: UnsafeMutableBufferPointer<UInt8>, width: Int, outHeight: Int,
                             ksize: Int, bounds: UnsafeBufferPointer<Int>, kk: UnsafeBufferPointer<Int32>) {
        let stride = width * 4
        for yy in 0..<outHeight {
            let ymin = bounds[yy * 2], ymax = bounds[yy * 2 + 1]
            let k = yy * ksize
            let lineOut = yy * stride
            for xx in 0..<width {
                var s0: Int32 = 1 << (precisionBits - 1), s1 = s0, s2 = s0, s3 = s0
                var p = ymin * stride + xx * 4
                for y in 0..<ymax {
                    let c = kk[k + y]
                    s0 &+= Int32(src[p]) &* c
                    s1 &+= Int32(src[p + 1]) &* c
                    s2 &+= Int32(src[p + 2]) &* c
                    s3 &+= Int32(src[p + 3]) &* c
                    p += stride
                }
                let o = lineOut + xx * 4
                dst[o] = clip8(s0)
                dst[o + 1] = clip8(s1)
                dst[o + 2] = clip8(s2)
                dst[o + 3] = clip8(s3)
            }
        }
    }

    // MARK: Quantizing (Quant.c and QuantOctree.c)

    /// The same layout as QuantOctree.c's struct _ColorBucket, which matters because the
    /// palette is sorted with the C library's qsort, as Pillow's is, so equal counts land in
    /// the same order.
    struct ColorBucket {
        var count: UInt32 = 0
        var r: UInt64 = 0
        var g: UInt64 = 0
        var b: UInt64 = 0
        var a: UInt64 = 0
    }

    struct ColorCube {
        let rBits, gBits, bBits, aBits: Int
        let rOffset, gOffset, bOffset: Int
        var buckets: [ColorBucket]

        init(_ r: Int, _ g: Int, _ b: Int, _ a: Int) {
            (rBits, gBits, bBits, aBits) = (r, g, b, a)
            rOffset = g + b + a
            gOffset = b + a
            bOffset = a
            buckets = [ColorBucket](repeating: ColorBucket(), count: 1 << (r + g + b + a))
        }

        var widths: [Int] { [1 << rBits, 1 << gBits, 1 << bBits, 1 << aBits] }

        @inline(__always)
        func offset(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
            r << rOffset | g << gOffset | b << bOffset | a
        }

        @inline(__always)
        func offset(pixel r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Int {
            offset(Int(r) >> (8 - rBits), Int(g) >> (8 - gBits), Int(b) >> (8 - bBits), Int(a) >> (8 - aBits))
        }

        var usedBuckets: Int { buckets.reduce(0) { $0 + ($1.count > 0 ? 1 : 0) } }
    }

    static func clip8(_ v: Int) -> UInt8 { v <= 0 ? 0 : v < 256 ? UInt8(v) : 255 }

    /// avg_color_from_color_bucket, with C's float division.
    static func average(_ bucket: ColorBucket) -> (UInt8, UInt8, UInt8, UInt8) {
        let count = Float(bucket.count)
        guard count != 0 else { return (0, 0, 0, 0) }
        return (clip8(Int(Float(bucket.r) / count)), clip8(Int(Float(bucket.g) / count)),
                clip8(Int(Float(bucket.b) / count)), clip8(Int(Float(bucket.a) / count)))
    }

    /// The fine cube's bucket for an RGBA pixel: 3, 4, 3 and 3 bits.
    @inline(__always)
    static func fineOffset(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        (Int(p[i]) >> 5) << 10 | (Int(p[i + 1]) >> 4) << 6 | (Int(p[i + 2]) >> 5) << 3 | Int(p[i + 3]) >> 5
    }

    /// ImagingQuantize: every fully transparent pixel takes the first one's colour, so they
    /// all fall into one bucket.
    static func unifyTransparent(_ p: UnsafeMutableBufferPointer<UInt8>) {
        var i = 3
        while i < p.count && p[i] != 0 { i += 4 }
        guard i < p.count else { return }
        let (r, g, b) = (p[i - 3], p[i - 2], p[i - 1])
        while i < p.count {
            if p[i] == 0 {
                p[i - 3] = r
                p[i - 2] = g
                p[i - 1] = b
            }
            i += 4
        }
    }

    static func fill(_ buckets: UnsafeMutableBufferPointer<ColorBucket>, from p: UnsafeBufferPointer<UInt8>) {
        var i = 0
        while i < p.count {
            let o = fineOffset(p, i)
            buckets[o].count &+= 1
            buckets[o].r &+= UInt64(p[i])
            buckets[o].g &+= UInt64(p[i + 1])
            buckets[o].b &+= UInt64(p[i + 2])
            buckets[o].a &+= UInt64(p[i + 3])
            i += 4
        }
    }

    static func map(_ p: UnsafeBufferPointer<UInt8>, through buckets: UnsafeBufferPointer<ColorBucket>, into out: UnsafeMutableBufferPointer<UInt8>) {
        for j in 0..<out.count {
            out[j] = UInt8(truncatingIfNeeded: buckets[fineOffset(p, j * 4)].count)
        }
    }

    static func sortedPalette(_ cube: ColorCube) -> [ColorBucket] {
        var buckets = cube.buckets
        buckets.withUnsafeMutableBufferPointer { buffer in
            qsort(buffer.baseAddress, buffer.count, MemoryLayout<ColorBucket>.stride) { a, b in
                let x = a!.assumingMemoryBound(to: ColorBucket.self).pointee.count
                let y = b!.assumingMemoryBound(to: ColorBucket.self).pointee.count
                // `return b->count - a->count;` in C: unsigned, then read as int.
                return Int32(bitPattern: y &- x)
            }
        }
        return buckets
    }

    /// copy_color_cube: shrinks or expands `cube` to the given bits, summing buckets.
    static func copy(_ cube: ColorCube, _ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorCube {
        var result = ColorCube(r, g, b, a)
        let srcBits = [cube.rBits, cube.gBits, cube.bBits, cube.aBits], dstBits = [r, g, b, a]
        var srcReduce = [0, 0, 0, 0], dstReduce = [0, 0, 0, 0], width = [0, 0, 0, 0]
        for i in 0..<4 {
            if srcBits[i] > dstBits[i] {
                dstReduce[i] = srcBits[i] - dstBits[i]
                width[i] = cube.widths[i]
            } else {
                srcReduce[i] = dstBits[i] - srcBits[i]
                width[i] = result.widths[i]
            }
        }
        for rr in 0..<width[0] {
            for gg in 0..<width[1] {
                for bb in 0..<width[2] {
                    for aa in 0..<width[3] {
                        let src = cube.buckets[cube.offset(rr >> srcReduce[0], gg >> srcReduce[1], bb >> srcReduce[2], aa >> srcReduce[3])]
                        let dst = result.offset(rr >> dstReduce[0], gg >> dstReduce[1], bb >> dstReduce[2], aa >> dstReduce[3])
                        result.buckets[dst].count &+= src.count
                        result.buckets[dst].r &+= src.r
                        result.buckets[dst].g &+= src.g
                        result.buckets[dst].b &+= src.b
                        result.buckets[dst].a &+= src.a
                    }
                }
            }
        }
        return result
    }

    static func subtract(_ cube: inout ColorCube, _ buckets: ArraySlice<ColorBucket>) {
        for subtrahend in buckets where subtrahend.count != 0 {
            let (r, g, b, a) = average(subtrahend)
            let i = cube.offset(pixel: r, g, b, a)
            cube.buckets[i].count &-= subtrahend.count
            cube.buckets[i].r &-= subtrahend.r
            cube.buckets[i].g &-= subtrahend.g
            cube.buckets[i].b &-= subtrahend.b
            cube.buckets[i].a &-= subtrahend.a
        }
    }

    static func addLookups(_ cube: inout ColorCube, _ palette: [ColorBucket], count: Int, offset: Int) {
        var i = offset + count - 1
        while i >= offset {
            let (r, g, b, a) = average(palette[i])
            cube.buckets[cube.offset(pixel: r, g, b, a)].count = UInt32(truncatingIfNeeded: i)
            i -= 1
        }
    }

    /// image.quantize(colors, method=FASTOCTREE) on an RGBA image: a 256-entry RGBA palette
    /// and one index per pixel.
    public static func quantizeOctree(_ image: RGBAImage, colors: Int = 256) -> (palette: [UInt8], indices: [UInt8]) {
        let n = image.width * image.height
        var pixels = image.pixels
        pixels.withUnsafeMutableBufferPointer { unifyTransparent($0) }
        // CUBE_LEVELS_ALPHA: a fine cube of 8x16x8x8 and a coarse one of 4x4x4x4.
        var fine = ColorCube(3, 4, 3, 3)
        pixels.withUnsafeBufferPointer { p in
            fine.buckets.withUnsafeMutableBufferPointer { fill($0, from: p) }
        }
        var coarse = copy(fine, 2, 2, 2, 2)
        var coarseColors = min(coarse.usedBuckets, colors)
        var fineColors = colors - coarseColors
        let finePalette = sortedPalette(fine)
        subtract(&coarse, finePalette[0..<fineColors])
        // Did the subtraction clear one or more coarse buckets? Then they can go to fine colours.
        while coarseColors > coarse.usedBuckets {
            let already = fineColors
            coarseColors = coarse.usedBuckets
            fineColors = colors - coarseColors
            subtract(&coarse, finePalette[already..<fineColors])
        }
        let coarsePalette = sortedPalette(coarse)
        let palette = Array(coarsePalette[0..<coarseColors]) + Array(finePalette[0..<fineColors])

        var coarseLookup = ColorCube(2, 2, 2, 2)
        addLookups(&coarseLookup, palette, count: coarseColors, offset: 0)
        // Each coarse bucket's value fills its fine buckets, then the fine colours go on top.
        var lookup = copy(coarseLookup, 3, 4, 3, 3)
        addLookups(&lookup, palette, count: fineColors, offset: coarseColors)

        var indices = [UInt8](repeating: 0, count: n)
        pixels.withUnsafeBufferPointer { p in
            lookup.buckets.withUnsafeBufferPointer { buckets in
                indices.withUnsafeMutableBufferPointer { map(p, through: buckets, into: $0) }
            }
        }
        var rgba = [UInt8]()
        rgba.reserveCapacity(colors * 4)
        for i in 0..<colors {
            let (r, g, b, a) = i < palette.count ? average(palette[i]) : (0, 0, 0, 0)
            rgba += [r, g, b, a]
        }
        return (rgba, indices)
    }
}
