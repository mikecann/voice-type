import Foundation
import Testing
@testable import VoiceTypeCore

struct WAVReaderTests {
    /// The bytes recording_archive.py writes: format 3, mono, 32-bit float, a fact chunk.
    func archiveWAV(_ samples: [Float], rate: UInt32 = 16000, channels: UInt16 = 1) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let body = samples.reduce(into: Data()) { $0 += le($1.bitPattern) }
        var fmt = Data()
        fmt += le(UInt16(3)) + le(channels) + le(rate) + le(rate * 4) + le(UInt16(4)) + le(UInt16(32))
        var chunks = Data("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        chunks += Data("fact".utf8) + le(UInt32(4)) + le(UInt32(samples.count))
        chunks += Data("data".utf8) + le(UInt32(body.count)) + body
        return Data("RIFF".utf8) + le(UInt32(chunks.count + 4)) + Data("WAVE".utf8) + chunks
    }

    @Test func readsTheArchivesFloatWAVExactly() throws {
        let samples: [Float] = [0, 0.5, -1, 1e-7, .leastNonzeroMagnitude, 0.123456789]
        #expect(try WAVReader.decode(archiveWAV(samples)) == samples)
    }

    @Test func readsPCM16LikeSoundfile() throws {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let pcm: [Int16] = [0, 16384, -32768, 32767]
        let body = pcm.reduce(into: Data()) { $0 += le($1) }
        // A LIST chunk before the data, which some writers add, must be skipped.
        let fmt = le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16000)) + le(UInt32(32000)) + le(UInt16(2)) + le(UInt16(16))
        let chunks = Data("fmt ".utf8) + le(UInt32(16)) + fmt
            + Data("LIST".utf8) + le(UInt32(3)) + Data([1, 2, 3, 0])
            + Data("data".utf8) + le(UInt32(body.count)) + body
        let wav = Data("RIFF".utf8) + le(UInt32(chunks.count + 4)) + Data("WAVE".utf8) + chunks
        #expect(try WAVReader.decode(wav) == [0, 0.5, -1, Float(32767) / 32768])
    }

    @Test func refusesWhatWouldNeedResampling() {
        #expect(throws: WAVError.unsupportedSampleRate(44100)) { try WAVReader.decode(archiveWAV([0], rate: 44100)) }
        #expect(throws: WAVError.unsupportedChannels(2)) { try WAVReader.decode(archiveWAV([0, 0], channels: 2)) }
        #expect(throws: WAVError.notWAV) { try WAVReader.decode(Data("hello world!".utf8)) }
    }

    @Test func rawFloatFilesAreReadAsTheBenchmarkWritesThem() throws {
        let samples: [Float] = [0.25, -0.75]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID()).f32")
        try samples.withUnsafeBytes { Data($0) }.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try WAVReader.readAudioFile(url) == samples)
    }
}
