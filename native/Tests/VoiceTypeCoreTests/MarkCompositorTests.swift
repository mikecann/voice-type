import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VoiceTypeCore
import VoiceTypeImaging

/// A palette PNG taken apart: what MarkCompositor and Pillow both write.
struct PalettePNG {
    var width = 0, height = 0, bitDepth = 0, colorType = 0
    var palette: [UInt8] = []
    var alpha: [UInt8] = []
    var icc: Data?
    /// The inflated IDAT stream: each row's filter byte and its filtered bytes.
    var filtered: [UInt8] = []
    var indices: [UInt8] = []
    var chunks: [String] = []
    /// Each palette entry as 0xRRGGBBAA.
    var colors: [UInt32] = []

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var i = 8
        var idat = Data()
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            let body = Array(bytes[i + 8..<i + 8 + length])
            chunks.append(type)
            switch type {
            case "IHDR":
                width = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
                height = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
                bitDepth = Int(body[8])
                colorType = Int(body[9])
            case "PLTE": palette = body
            case "tRNS": alpha = body
            case "iCCP": icc = PNGWriter.iccProfile(in: Data(bytes[0..<8] + bytes[i..<i + 12 + length]))
            case "IDAT": idat.append(contentsOf: body)
            default: break
            }
            i += 12 + length
        }
        filtered = [UInt8](try PNGWriter.inflate(idat))
        guard colorType == 3, bitDepth == 8 else { return }
        colors = (0..<palette.count / 3).map { i in
            UInt32(palette[i * 3]) << 24 | UInt32(palette[i * 3 + 1]) << 16 | UInt32(palette[i * 3 + 2]) << 8 | UInt32(i < alpha.count ? alpha[i] : 255)
        }
        // Undo the filters (one byte per pixel).
        var previous = [UInt8](repeating: 0, count: width)
        indices.reserveCapacity(width * height)
        for y in 0..<height {
            let row = y * (width + 1)
            if filtered[row] == 0 {
                // Unfiltered, which is all Pillow and MarkCompositor write.
                previous = Array(filtered[(row + 1)...(row + width)])
                indices += previous
                continue
            }
            var line = [UInt8](repeating: 0, count: width)
            for x in 0..<width {
                let v = filtered[row + 1 + x]
                let a = x > 0 ? Int(line[x - 1]) : 0, b = Int(previous[x]), c = x > 0 ? Int(previous[x - 1]) : 0
                switch filtered[row] {
                case 0: line[x] = v
                case 1: line[x] = v &+ UInt8(a)
                case 2: line[x] = v &+ UInt8(b)
                case 3: line[x] = v &+ UInt8((a + b) / 2)
                default:
                    let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                    line[x] = v &+ UInt8(pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
                }
            }
            indices += line
            previous = line
        }
    }

    func rgba(_ x: Int, _ y: Int) -> [Int] {
        let c = colors[Int(indices[y * width + x])]
        return [Int(c >> 24), Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF)]
    }
}

/// Whether two 0xRRGGBBAA colours are within `tolerance` on every channel.
func close(_ a: UInt32, _ b: UInt32, within tolerance: Int) -> Bool {
    var shift: UInt32 = 0
    while shift < 32 {
        if abs(Int(a >> shift & 0xFF) - Int(b >> shift & 0xFF)) > tolerance { return false }
        shift += 8
    }
    return true
}

/// A white window capture written with ImageIO, standing in for screencapture's output:
/// square, or with antialiased rounded corners like a real window's.
func capturePNG(width: Int, height: Int, cornerRadius: Double = 0, white: Bool = true) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if white {
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.fillPath()
    }
    let image = context.makeImage()!
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func close(_ a: [Int], _ b: [Int], within tolerance: Int = 2) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

let ink = [255, 59, 48, 255]

// Ported from CompositeTests in tests/test_mark_capture.py.
struct CompositeTests {
    func composite(_ png: Data, _ rect: MarkRect, _ strokes: [Stroke]) throws -> PalettePNG {
        try PalettePNG(MarkCompositor.compositePNG(png, captureRect: rect, strokes: strokes))
    }

    @Test func inkLandsAtTheRightRetinaPixels() throws {
        // A window at (200, 100) points, 400x300 points, captured at 2x.
        let white = capturePNG(width: 800, height: 600)
        let result = try composite(white, MarkRect(200, 100, 400, 300), [arrow((250, 200), (450, 200))])
        #expect((result.width, result.height) == (800, 600))
        // Midway along the arrow: (350, 200) points -> (300, 200) pixels.
        #expect(close(result.rgba(300, 200), ink))
        // Well away from the ink stays white.
        #expect(close(result.rgba(300, 400), [255, 255, 255, 255]))
    }

    @Test func everyMarkInAGroupIsDrawnOnOneImage() throws {
        let white = capturePNG(width: 800, height: 600)
        let result = try composite(white, MarkRect(200, 100, 400, 300), [arrow((250, 150), (450, 150), 1), arrow((250, 300), (450, 300), 2)])
        #expect(close(result.rgba(300, 100), ink))
        #expect(close(result.rgba(300, 400), ink))
        #expect(close(result.rgba(300, 250), [255, 255, 255, 255]))
    }

    @Test func outputIsASmallPalettePNGThatKeepsTransparentCorners() throws {
        // A big Retina window with antialiased rounded corners.
        let capture = capturePNG(width: 3456, height: 2234, cornerRadius: 40)
        let result = try composite(capture, MarkRect(0, 0, 1728, 1117), [Stroke(points: pts([(800, 500)]), startedAt: 0, endedAt: 1, number: 1)])
        #expect(result.colorType == 3)
        #expect(max(result.width, result.height) == 1568)
        #expect(result.rgba(1, 1)[3] == 0)
        // Antialiased corners mustn't leave the body of the window see-through.
        #expect(result.rgba(700, 700)[3] == 255)
    }

    @Test func aBlankCaptureStillMakesAPNG() throws {
        let clear = capturePNG(width: 64, height: 48, white: false)
        let result = try composite(clear, MarkRect(0, 0, 64, 48), [])
        #expect((result.width, result.height) == (64, 48))
        #expect(result.rgba(10, 10)[3] == 0)
    }

    @Test func aBadCaptureIsAnError() {
        #expect(throws: (any Error).self) { try MarkCompositor.compositePNG(Data("not a png".utf8), captureRect: MarkRect(0, 0, 1, 1), strokes: []) }
    }
}

/// Against Python's own composite_png on the same synthetic captures
/// (scripts/make-mark-fixtures.py).
struct GoldenCompositeTests {
    struct Case: Decodable {
        struct Mark: Decodable {
            var number: Int
            var kind: String
            var points: [[Double]]
        }
        var name: String
        var rect: [Double]
        var marks: [Mark]
        var python_bytes: Int
        var python_plain_bytes: Int

        var captureRect: MarkRect { MarkRect(rect[0], rect[1], rect[2], rect[3]) }
        var strokes: [Stroke] {
            marks.map { Stroke(points: $0.points.map { MarkPoint($0[0], $0[1]) }, startedAt: 0, endedAt: 1, number: $0.number) }
        }
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/marks") else {
            throw PNGError("no fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    static let cases: [Case] = (try? JSONDecoder().decode([Case].self, from: fixture("manifest.json"))) ?? []

    @Test func theManifestHasEveryCase() {
        #expect(Self.cases.map(\.name) == ["window-2x", "window-large", "desktop-1x"])
    }

    @Test(arguments: cases.map(\.name))
    func strokesClassifyAsTheyDidInPython(_ name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        #expect(c.strokes.map(\.kind.rawValue) == c.marks.map(\.kind))
    }

    /// Without ink the two pipelines see exactly the same pixels, so the shrink, the
    /// quantizer, the alpha snap and the PNG filters must all agree to the byte.
    @Test(arguments: cases.map(\.name))
    func withoutInkTheImageMatchesPythonExactly(_ name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let capture = try Self.fixture("\(name).capture.png")
        let native = try MarkCompositor.compositePNG(capture, captureRect: c.captureRect, strokes: [])
        let ours = try PalettePNG(native), python = try PalettePNG(Self.fixture("\(name).python-plain.png"))
        #expect((ours.width, ours.height, ours.bitDepth, ours.colorType) == (python.width, python.height, python.bitDepth, python.colorType))
        #expect(ours.chunks.filter { $0 != "IDAT" } == python.chunks.filter { $0 != "IDAT" })
        #expect(ours.palette == python.palette)
        #expect(ours.alpha == python.alpha)
        #expect(ours.icc == python.icc)
        #expect(ours.filtered == python.filtered)
        // Only zlib differs (Pillow's is zlib-ng at level 9, ours the system's at 7).
        #expect(abs(native.count - c.python_plain_bytes) < c.python_plain_bytes * 15 / 100, "\(native.count) bytes against Python's \(c.python_plain_bytes)")
    }

    /// With ink, Core Graphics antialiases where Pillow didn't, so edge pixels differ (at 1x
    /// a 4 px line is mostly edge, where Pillow's jagged one is solid red), but the picture
    /// is the same: the ink is in the same places and everything else matches.
    @Test(arguments: cases.map(\.name))
    func withInkTheImageMatchesPython(_ name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let capture = try Self.fixture("\(name).capture.png")
        let native = try MarkCompositor.compositePNG(capture, captureRect: c.captureRect, strokes: c.strokes)
        let ours = try PalettePNG(native), python = try PalettePNG(Self.fixture("\(name).python.png"))
        #expect((ours.width, ours.height) == (python.width, python.height))
        var different = 0, inkOurs = 0, inkPython = 0, inkBoth = 0
        let red: UInt32 = 0xFF3B_30FF
        for i in 0..<ours.indices.count {
            let a = ours.colors[Int(ours.indices[i])], b = python.colors[Int(python.indices[i])]
            if !close(a, b, within: 24) { different += 1 }
            let inkA = close(a, red, within: 12), inkB = close(b, red, within: 12)
            if inkA { inkOurs += 1 }
            if inkB { inkPython += 1 }
            if inkA && inkB { inkBoth += 1 }
        }
        let total = ours.width * ours.height
        // Away from the ink's edges, everything agrees.
        #expect(Double(different) / Double(total) < 0.004, "\(different) of \(total) pixels differ")
        // The ink is in the same places: most of Python's solid red is solid red here too,
        // and there's about as much of it.
        #expect(inkPython > 500)
        #expect(Double(inkBoth) / Double(inkPython) > 0.75, "ours \(inkOurs), Python's \(inkPython), both \(inkBoth)")
        #expect(Double(inkOurs) / Double(inkPython) > 0.7 && Double(inkOurs) / Double(inkPython) < 1.3)
        // zlib level 7 against Pillow's 9 costs more on these flat synthetic windows than on
        // real ones (0 to 5% on Python's own screenshots).
        #expect(abs(native.count - c.python_bytes) < c.python_bytes * 15 / 100, "\(native.count) bytes against Python's \(c.python_bytes)")
    }
}
