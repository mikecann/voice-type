import Foundation
import Testing
@testable import VoiceTypeCore

/// The Python app's own files, written by native/scripts/make-python-fixtures.py with the
/// real recording_archive.py, transcription_history.py and json.dump.
func pythonFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/python"))
    return try Data(contentsOf: url)
}

func temporaryDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(label)-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct PythonJSONTests {
    @Test func writesPythonsIndentedFormat() throws {
        let value = try OrderedJSONParser.parse(pythonFixture("settings.json"))
        #expect(PythonJSON.dumps(value, indent: 2, ensureASCII: true) == String(decoding: try pythonFixture("settings.json"), as: UTF8.self))
    }

    @Test func compactFormHasSpacesAfterSeparators() {
        let value = JSONValue.object([("a", .int(1)), ("b", .array([.bool(true), .null])), ("c", .object([]))])
        #expect(PythonJSON.dumps(value) == #"{"a": 1, "b": [true, null], "c": {}}"#)
    }

    @Test func escapesLikePython() {
        let s = JSONValue.string("q\" b\\ \u{01} \u{1F} \u{7F} é 🎙 \u{2028}\n\t")
        #expect(PythonJSON.dumps(s, ensureASCII: false) == "\"q\\\" b\\\\ \\u0001 \\u001f \u{7F} é 🎙 \u{2028}\\n\\t\"")
        #expect(PythonJSON.dumps(s, ensureASCII: true) == "\"q\\\" b\\\\ \\u0001 \\u001f \u{7F} \\u00e9 \\ud83c\\udf99 \\u2028\\n\\t\"")
    }

    @Test func floatsUsePythonsRepr() {
        // Each pair is a value and Python's repr of it.
        let cases: [(Double, String)] = [
            (0, "0.0"), (2.32, "2.32"), (1e-4, "0.0001"), (1e-5, "1e-05"), (1.5e-7, "1.5e-07"),
            (1e15, "1000000000000000.0"), (1e16, "1e+16"), (0.14399999999999999, "0.144"),
            (2.007343735677125e-10, "2.007343735677125e-10"), (-0.0, "-0.0"),
        ]
        for (value, repr) in cases {
            #expect(PythonJSON.dumps(.double(value)) == repr)
        }
        #expect(PythonJSON.dumps(.double(.nan)) == "NaN")
        #expect(PythonJSON.dumps(.double(-.infinity)) == "-Infinity")
    }

    @Test func settingKeysKeepsDictOrder() {
        var value = JSONValue.object([("a", .int(1)), ("b", .int(2))])
        value.set("a", .int(3))
        value.set("c", .int(4))
        #expect(value.objectPairs?.map(\.key) == ["a", "b", "c"])
        #expect(value["a"] == .int(3))
    }
}

struct TimestampTests {
    @Test func formatsLikePythonsDatetime() {
        let t = Timestamp.make(year: 2026, month: 10, day: 24, hour: 2, minute: 31, second: 11, micro: 950_600, offsetSeconds: 0)
        #expect(t.recordingIDPrefix == "20261024T023111950600Z")
        #expect(t.utcISOFormat == "2026-10-24T02:31:11.950600+00:00")
        #expect(t.localISOFormatSeconds(timeZone: TimeZone(secondsFromGMT: 11 * 3600)!) == "2026-10-24T13:31:11+11:00")
        #expect(t.localISOFormatSeconds(timeZone: TimeZone(secondsFromGMT: -(4 * 3600 + 30 * 60))!) == "2026-10-23T22:01:11-04:30")
        let whole = Timestamp.make(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5, micro: 0, offsetSeconds: 0)
        #expect(whole.utcISOFormat == "2026-01-02T03:04:05+00:00")
    }

    @Test func roundTripsThroughDate() {
        let t = Timestamp(Date(timeIntervalSince1970: 1_792_548_671.9506))
        #expect(t.microseconds == 1_792_548_671_950_600)
        #expect(Timestamp.parseRecordingIDPrefix(t.recordingIDPrefix) == t)
    }

    @Test func parsesTheISOFormsVoiceTypeWrites() throws {
        let aware = try #require(Timestamp.parseISO("2026-08-04T09:00:00+08:00"))
        #expect(aware.offsetSeconds == 8 * 3600)
        #expect(aware.timestamp(assumingOffset: 0) == Timestamp.make(year: 2026, month: 8, day: 4, hour: 1, minute: 0, second: 0, micro: 0, offsetSeconds: 0))
        let naive = try #require(Timestamp.parseISO("2026-08-04T09:00:00"))
        #expect(naive.offsetSeconds == nil)
        #expect(Timestamp.parseISO("2026-10-24T02:31:11.950600+00:00")?.timestamp(assumingOffset: 0).utcISOFormat == "2026-10-24T02:31:11.950600+00:00")
        #expect(Timestamp.parseISO("yesterday") == nil)
    }
}

struct RecordingArchiveTests {
    let now = Timestamp.make(year: 2026, month: 10, day: 24, hour: 2, minute: 31, second: 11, micro: 950_600, offsetSeconds: 0).date
    let audio: [Float] = [0.0, -0.1234567, 0.9876543, 1e-7, -1.0, 0.5]

    func metadata() -> [(key: String, value: JSONValue)] {
        [
            ("mode", .string("final_only")),
            ("final_model", .string("large-v3-turbo")),
            ("stream_model", .string("large-v3-turbo")),
            ("microphone", .string("Yeti Stereo Microphone")),
            ("preferred_microphone", .string("Yeti Stereo Microphone")),
            ("key_hold_seconds", .double(2.361856874951627)),
            ("capture_ready_delay_seconds", .double(0.03931699995882809)),
            ("first_audio_delay_seconds", .null),
            ("formatter_enabled", .bool(false)),
            ("vocabulary", .strings(["Convex", "Café", "Sammy Cam"])),
        ]
    }

    @Test func writesTheSameBytesAsPython() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir, clock: { now }, makeHexID: { "5b176e01cb8a40ddbd9e2fa3bdf9e8c7" })
        let id = try archive.save(audio, sampleRate: 16000, metadata: metadata())
        #expect(id == "20261024T023111950600Z_5b176e01cb8a40ddbd9e2fa3bdf9e8c7")
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id).json")) == pythonFixture("recording-captured.json"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id).wav")) == pythonFixture("recording.wav"))

        try archive.update(id, [("raw_transcript", .string("Hey, I noticed a bit of lag \"quoted\" \u{2014} ok\ttab")),
                                ("decoded_text", .string("Hey, I noticed a bit of lag."))])
        try archive.update(id, [("text", .string("Hey, I noticed a bit of lag.")), ("status", .string("completed"))])
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id).json")) == pythonFixture("recording.json"))
    }

    @Test func wholeSecondsAndEmptyAudioMatchToo() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = Timestamp.make(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5, micro: 0, offsetSeconds: 0).date
        let archive = RecordingArchive(directory: dir, clock: { whole }, makeHexID: { "00000000000000000000000000000002" })
        let id = try archive.save([], sampleRate: 16000, metadata: [("x", .int(1))])
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id).json")) == pythonFixture("recording-whole-second.json"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id).wav")) == pythonFixture("recording-whole-second.wav"))

        let two = RecordingArchive(directory: dir, clock: { now }, makeHexID: { "00000000000000000000000000000001" })
        let id2 = try two.save([Float](repeating: 0, count: 32000), sampleRate: 16000, metadata: [])
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(id2).json")) == pythonFixture("recording-empty-metadata.json"))
    }

    @Test func savedAudioReadsBackExactly() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir)
        let id = try archive.save(audio, sampleRate: 16000, metadata: [])
        #expect(try WAVReader.read(dir.appendingPathComponent("\(id).wav")) == audio)
    }

    @Test func filesAreOwnerOnlyAndNoTemporaryFilesRemain() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("recordings")
        let id = try RecordingArchive(directory: root).save([0], sampleRate: 16000, metadata: [])
        func mode(_ url: URL) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }
        #expect(try mode(root) == 0o700)
        #expect(try mode(root.appendingPathComponent("\(id).wav")) == 0o600)
        #expect(try mode(root.appendingPathComponent("\(id).json")) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["\(id).json", "\(id).wav"])
    }

    @Test func cleanupExpiresByRecordingTimeAndLeavesOtherFiles() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        var clockNow = now
        let archive = RecordingArchive(directory: dir, clock: { clockNow })
        let old = try archive.save([0], sampleRate: 16000, metadata: [])
        clockNow = now.addingTimeInterval(30 * 86_400)
        archive.cleanup()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(old).wav").path))
        let fresh = try archive.save([0], sampleRate: 16000, metadata: [])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(old).json"))  // an orphaned WAV
        try Data("unrelated".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        try Data().write(to: dir.appendingPathComponent("\(old).json.tmp"))  // an interrupted write
        clockNow = clockNow.addingTimeInterval(1)
        #expect(archive.cleanup() == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(old).wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(fresh).wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.txt").path))
    }

    @Test func lateUpdateDoesNotRecreateAnExpiredRecording() throws {
        let dir = try temporaryDirectory("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir)
        let id = try archive.save([0], sampleRate: 16000, metadata: [])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        try archive.update(id, [("status", .string("completed"))])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path))
    }

    @Test func recognisesOnlyItsOwnFileNames() {
        #expect(RecordingArchive.captureTime(ofFileNamed: "20261024T023111950600Z_5b176e01cb8a40ddbd9e2fa3bdf9e8c7.wav") != nil)
        #expect(RecordingArchive.captureTime(ofFileNamed: "20261024T023111950600Z_5b176e01cb8a40ddbd9e2fa3bdf9e8c7.json.tmp") != nil)
        #expect(RecordingArchive.captureTime(ofFileNamed: "20261024T023111950600Z_5B176E01CB8A40DDBD9E2FA3BDF9E8C7.wav") == nil)
        #expect(RecordingArchive.captureTime(ofFileNamed: "20261024T023111950600Z_5b176e01cb8a40ddbd9e2fa3bdf9e8c7.png") == nil)
        #expect(RecordingArchive.captureTime(ofFileNamed: "keep.txt") == nil)
    }
}

struct TranscriptionHistoryTests {
    let zone = TimeZone(secondsFromGMT: 11 * 3600)!
    let now = Timestamp.make(year: 2026, month: 10, day: 24, hour: 2, minute: 31, second: 11, micro: 0, offsetSeconds: 0).date

    @Test func appendsTheSameLinesAsPython() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcription-history.jsonl")
        let history = TranscriptionHistory(url: url, clock: { now }, timeZone: zone)
        #expect(try history.append("  First one, with \"quotes\" and café.  ", mode: "final_only"))
        #expect(try history.append("Second 🎙 line", mode: "final_only", createdAt: "2026-10-24T13:32:00+11:00"))
        #expect(try Data(contentsOf: url) == pythonFixture("transcription-history.jsonl"))
    }

    // Ported from tests/test_transcription_history.py.
    let pythonNow = Timestamp.make(year: 2026, month: 8, day: 4, hour: 2, minute: 0, second: 0, micro: 0, offsetSeconds: 0).date

    @Test func appendReturnsNewestFirstAndIgnoresBlankText() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = TranscriptionHistory(url: dir.appendingPathComponent("h.jsonl"), clock: { pythonNow })
        try history.append("first recording", mode: "final_only", createdAt: "2026-08-04T09:00:00+08:00")
        #expect(try !history.append("  ", mode: "final_only", createdAt: "2026-08-04T09:01:00+08:00"))
        try history.append("second recording", mode: "precompute", createdAt: "2026-08-04T09:02:00+08:00")
        let entries = try history.load()
        #expect(entries.map(\.text) == ["second recording", "first recording"])
        #expect(entries[0].mode == "precompute")
    }

    @Test func loadSkipsAPartialOrCorruptFinalLine() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("h.jsonl")
        try Data((#"{"created_at": "2026-08-04T09:00:00+08:00", "mode": "final_only", "text": "safe"}"# + "\n{unfinished").utf8).write(to: url)
        #expect(try TranscriptionHistory(url: url, clock: { pythonNow }).load().map(\.text) == ["safe"])
        // Compaction rewrote the file without the broken line.
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("unfinished"))
    }

    @Test func retentionKeepsOnlyTheMostRecentEntries() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = TranscriptionHistory(url: dir.appendingPathComponent("h.jsonl"), maxEntries: 2, clock: { pythonNow })
        try history.append("one", mode: "final_only", createdAt: "2026-08-04T09:00:00+08:00")
        try history.append("two", mode: "final_only", createdAt: "2026-08-04T09:01:00+08:00")
        try history.append("three", mode: "final_only", createdAt: "2026-08-04T09:02:00+08:00")
        #expect(try history.load().map(\.text) == ["three", "two"])
    }

    @Test func retentionRemovesEntriesOlderThanThirtyDays() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Timestamp.make(year: 2026, month: 8, day: 4, hour: 10, minute: 0, second: 0, micro: 0, offsetSeconds: 0).date
        let history = TranscriptionHistory(url: dir.appendingPathComponent("h.jsonl"), clock: { now })
        try history.append("too old", mode: "final_only", createdAt: "2026-07-05T09:59:59+00:00")
        try history.append("boundary", mode: "final_only", createdAt: "2026-07-05T10:00:00+00:00")
        try history.append("recent", mode: "final_only", createdAt: "2026-08-04T09:00:00+00:00")
        #expect(try history.load().map(\.text) == ["recent", "boundary"])
    }

    @Test func duplicatesAreIgnoredByLocalSecond() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = TranscriptionHistory(url: dir.appendingPathComponent("h.jsonl"), clock: { pythonNow })
        #expect(try history.append("same", mode: "final_only", createdAt: "2026-08-04T09:00:00+08:00"))
        #expect(try !history.append("same", mode: "final_only", createdAt: "2026-08-04T09:00:00"))
    }
}

struct SettingsFileTests {
    @Test func rewritesSettingsAsPythonWouldKeepingUnknownKeys() throws {
        let dir = try temporaryDirectory("settings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try pythonFixture("settings.json").write(to: url)
        var settings = SettingsFile.load(from: url)
        #expect(settings.microphoneName == "Yeti Stereo Microphone")
        #expect(settings.audioRecordingEnabled)
        #expect(settings.native("microphone") == .string("x"))
        try settings.save()
        #expect(try Data(contentsOf: url) == pythonFixture("settings.json"))

        settings.set("microphone_name", .string(""))
        settings.setNative("last_switch", .string("native"))
        try settings.save()
        let reread = SettingsFile.load(from: url)
        #expect(reread.microphoneName == "")
        #expect(reread.json.objectPairs?.map(\.key) == settings.json.objectPairs?.map(\.key))
        #expect(reread.native("last_switch") == .string("native"))
        #expect(reread.dictation.vocabularyPrompt == "Convex, Café.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
    }

    @Test func missingKeysGetPythonsDefaults() {
        let settings = SettingsFile(url: URL(fileURLWithPath: "/nonexistent"), json: .object([]))
        #expect(settings.microphoneName == "Yeti Stereo Microphone")
        #expect(!settings.audioRecordingEnabled)
        #expect(settings.drawOnScreenEnabled)
        #expect(settings.vocabularyForRecording == .strings(VoiceTypeSettings.defaultVocabulary))
    }
}
