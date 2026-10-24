import Foundation

public enum WAVError: LocalizedError, CustomStringConvertible, Equatable {
    case notWAV
    case missingChunk(String)
    case unsupportedFormat(tag: UInt16, bits: UInt16)
    case unsupportedChannels(UInt16)
    case unsupportedSampleRate(UInt32)

    public var description: String {
        switch self {
        case .notWAV: return "not a RIFF/WAVE file"
        case let .missingChunk(id): return "WAV file has no \(id) chunk"
        case let .unsupportedFormat(tag, bits): return "unsupported WAV format \(tag) with \(bits)-bit samples"
        case let .unsupportedChannels(n): return "WAV has \(n) channels; only mono is supported"
        case let .unsupportedSampleRate(rate):
            return "WAV is \(rate) Hz; only 16 kHz is supported (Voice Type records at 16 kHz)"
        }
    }

    public var errorDescription: String? { description }
}

/// Reads the WAV files Voice Type saves, giving Whisper the same samples Python gave it.
///
/// recording_archive.py writes mono 32-bit float WAVs at 16 kHz (format 3, with a fact
/// chunk) so a replay sees exactly what Whisper saw. The benchmark read them with
/// soundfile as float32, which is a straight copy, and never resampled them. 16-bit PCM is
/// also accepted, scaled by 1/32768 as soundfile does. Anything not at 16 kHz is refused
/// rather than resampled, because no recording needs it and a resampler that differed from
/// ffmpeg's would quietly change the text.
public enum WAVReader {
    public static func read(_ url: URL) throws -> [Float] {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func id(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }

        guard bytes.count >= 12, id(0) == "RIFF", id(8) == "WAVE" else { throw WAVError.notWAV }

        var format: (tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunk = id(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            let end = min(body + size, bytes.count)
            if chunk == "fmt ", end - body >= 16 {
                var tag = u16(body)
                let bits = u16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE keeps the real format in its sub-format GUID.
                if tag == 0xFFFE, end - body >= 26 { tag = u16(body + 24) }
                format = (tag, u16(body + 2), u32(body + 4), bits)
            } else if chunk == "data" {
                guard let format else { throw WAVError.missingChunk("fmt ") }
                guard format.channels == 1 else { throw WAVError.unsupportedChannels(format.channels) }
                guard format.rate == UInt32(sampleRate) else { throw WAVError.unsupportedSampleRate(format.rate) }
                return try samples(bytes[body..<end], tag: format.tag, bits: format.bits)
            }
            // Chunks are padded to an even length.
            offset = body + size + (size & 1)
        }
        throw WAVError.missingChunk("data")
    }

    private static func samples(_ body: ArraySlice<UInt8>, tag: UInt16, bits: UInt16) throws -> [Float] {
        switch (tag, bits) {
        case (3, 32):
            return body.withUnsafeBytes { raw in
                (0..<raw.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
        case (1, 16):
            return body.withUnsafeBytes { raw in
                (0..<raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
        default:
            throw WAVError.unsupportedFormat(tag: tag, bits: bits)
        }
    }

    /// Raw little-endian float32 samples, as the benchmark writes them for its Swift servers.
    public static func decodeRawFloat32(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    /// A WAV if the file says so, otherwise raw float32 like whispercpp-bench expects.
    public static func readAudioFile(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        if data.count >= 4, data.prefix(4) == Data("RIFF".utf8) { return try decode(data) }
        return decodeRawFloat32(data)
    }
}
