/// MarkCompositor's per-pixel loops, here so they're always optimised.
public enum PixelLoops {
    /// Decoded 8-bit RGB rows (RGBA, ARGB, either byte order, or plain RGB) as straight RGBA.
    public static func copyPixels(_ src: UnsafeRawBufferPointer, _ dst: UnsafeMutableBufferPointer<UInt8>, width w: Int, height h: Int, rowBytes: Int,
                           bytesPerPixel bpp: Int, littleEndian: Bool, alphaFirst: Bool, opaque: Bool) {
        for y in 0..<h {
            var s = y * rowBytes
            var d = y * w * 4
            for _ in 0..<w {
                if bpp == 3 {
                    dst[d] = src[s]
                    dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s + 2]
                } else {
                    // In memory order: RGBA, ARGB, or (little endian) ABGR and BGRA.
                    var c = (src[s], src[s + 1], src[s + 2], src[s + 3])
                    if littleEndian { c = (c.3, c.2, c.1, c.0) }
                    let (a, r, g, b) = alphaFirst ? (c.0, c.1, c.2, c.3) : (c.3, c.0, c.1, c.2)
                    dst[d] = r
                    dst[d + 1] = g
                    dst[d + 2] = b
                    dst[d + 3] = opaque ? 255 : a
                }
                s += bpp
                d += 4
            }
        }
    }

    /// Source over, with the layer premultiplied and the capture straight. Fully covered
    /// pixels take the ink's values exactly, as Pillow's jagged drawing set them.
    public static func layOver(_ src: UnsafeBufferPointer<UInt8>, layerX lx: Int, layerY ly: Int, layerWidth lw: Int, layerHeight lh: Int,
                        onto dst: UnsafeMutableBufferPointer<UInt8>, width: Int) {
        for y in 0..<lh {
            for x in 0..<lw {
                let s = (y * lw + x) * 4
                let la = Int(src[s + 3])
                guard la > 0 else { continue }
                let d = ((ly + y) * width + lx + x) * 4
                if la == 255 {
                    dst[d] = src[s]
                    dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s + 2]
                    dst[d + 3] = 255
                    continue
                }
                let da = Double(dst[d + 3]) / 255, sa = Double(la) / 255
                let outA = sa + da * (1 - sa)
                for c in 0..<3 {
                    let premultiplied = Double(src[s + c]) / 255 + Double(dst[d + c]) / 255 * da * (1 - sa)
                    dst[d + c] = UInt8(max(0, min(255, (premultiplied / outA * 255).rounded())))
                }
                dst[d + 3] = UInt8(max(0, min(255, (outA * 255).rounded())))
            }
        }
    }
}
