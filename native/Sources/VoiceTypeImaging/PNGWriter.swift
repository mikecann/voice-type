import Foundation
import zlib

public struct PNGError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Writes an 8-bit palette PNG the way Pillow's `save(format="PNG", optimize=True)` does
/// for a quantized RGBA image: IHDR, the source's ICC profile, a 256-colour PLTE, a tRNS
/// with every entry's alpha, and unfiltered IDAT rows, deflated by the system zlib.
public enum PNGWriter {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Pillow writes IDAT in pieces of this size.
    static let idatChunk = 65_536
    static let deflateLevel: Int32 = 7

    public static func palettePNG(width: Int, height: Int, palette: [UInt8], indices: [UInt8], iccProfile: Data?) throws -> Data {
        precondition(palette.count % 4 == 0 && indices.count == width * height)
        var out = Data(signature)
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 3, 0, 0, 0])
        appendChunk("IHDR", header, to: &out)
        if let iccProfile {
            // As Pillow does: a fixed name, then the profile at zlib's default level.
            var body = Data("ICC Profile".utf8)
            body.append(contentsOf: [0, 0])
            body.append(try deflate([UInt8](iccProfile), level: Z_DEFAULT_COMPRESSION, strategy: Z_DEFAULT_STRATEGY, memLevel: 8))
            appendChunk("iCCP", body, to: &out)
        }
        let colors = palette.count / 4
        var plte = Data(capacity: colors * 3)
        var trns = Data(capacity: colors)
        for i in 0..<colors {
            plte.append(contentsOf: palette[i * 4..<i * 4 + 3])
            trns.append(palette[i * 4 + 3])
        }
        appendChunk("PLTE", plte, to: &out)
        appendChunk("tRNS", trns, to: &out)
        // Pillow's optimize uses level 9, but macOS's zlib (1.2.12) is much slower there than
        // the zlib-ng Pillow bundles: up to 0.4 s on a busy Retina window against 0.05 s at
        // level 7, for files 1 to 3% smaller. Level 7 keeps each capture quicker than
        // Python's whole composite, which matters for the mark drawn just before key-up.
        let compressed = try deflate(rows(width: width, height: height, indices: indices), level: deflateLevel,
                                     strategy: Z_DEFAULT_STRATEGY, memLevel: 9)
        var offset = 0
        repeat {
            let end = min(offset + idatChunk, compressed.count)
            appendChunk("IDAT", compressed.subdata(in: offset..<end), to: &out)
            offset = end
        } while offset < compressed.count
        appendChunk("IEND", Data(), to: &out)
        return out
    }

    /// Each row behind a zero filter byte. Pillow turns PNG filtering off for palette images
    /// (encode.c's ZIP_PNG_PALETTE), since an index's neighbours say nothing about it.
    static func rows(width: Int, height: Int, indices: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (width + 1) * height)
        indices.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = UnsafeMutableBufferPointer(rebasing: dst[(y * (width + 1) + 1)..<((y + 1) * (width + 1))])
                    _ = row.initialize(from: src[(y * width)..<((y + 1) * width)])
                }
            }
        }
        return out
    }

    static func deflate(_ input: [UInt8], level: Int32, strategy: Int32, memLevel: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15, memLevel, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PNGError("zlib wouldn't start")
        }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        let status: Int32 = input.withUnsafeBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: inBuffer.baseAddress)
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw PNGError("zlib couldn't compress the image (\(status))") }
        return Data(output[0..<Int(stream.total_out)])
    }

    public static func inflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PNGError("zlib wouldn't start") }
        defer { inflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let bytes = [UInt8](input)
        var status: Int32 = Z_OK
        bytes.withUnsafeBufferPointer { inBuffer in
            stream.next_in = UnsafeMutablePointer(mutating: inBuffer.baseAddress)
            stream.avail_in = uInt(inBuffer.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { outBuffer in
                    stream.next_out = outBuffer.baseAddress
                    stream.avail_out = uInt(outBuffer.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw PNGError("zlib couldn't decompress (\(status))") }
        return output
    }

    static func appendChunk(_ type: String, _ body: Data, to out: inout Data) {
        out.appendBigEndian(UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        out.append(typed)
        let crc = typed.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        out.appendBigEndian(UInt32(crc))
    }

    /// The decompressed ICC profile from a PNG's iCCP chunk, which Pillow carries through to
    /// the screenshot it saves. Nil without one.
    public static func iccProfile(in png: Data) -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            let start = i + 8, end = start + length
            guard end <= bytes.count else { return nil }
            if type == "iCCP" {
                // Name, a zero, the compression method (0), then the deflated profile.
                guard let zero = bytes[start..<end].firstIndex(of: 0), zero + 2 <= end else { return nil }
                return try? inflate(Data(bytes[(zero + 2)..<end]))
            }
            if type == "IDAT" || type == "IEND" { return nil }
            i = end + 4
        }
        return nil
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
