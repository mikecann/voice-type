import Foundation
import Testing
@testable import VoiceTypeCore

struct OrderedJSONTests {
    func parse(_ text: String) throws -> JSONValue {
        try OrderedJSONParser.parse(Data(text.utf8))
    }

    @Test func keepsKeyOrder() throws {
        let value = try parse(#"{"b": 1, "a": [true, null, "x"], "c": {"z": 2, "y": 3}}"#)
        guard case let .object(pairs) = value, case let .object(inner)? = value["c"] else {
            Issue.record("not an object")
            return
        }
        #expect(pairs.map(\.key) == ["b", "a", "c"])
        #expect(inner.map(\.key) == ["z", "y"])
        #expect(value["a"] == .array([.bool(true), .null, .string("x")]))
    }

    @Test func repeatedKeyKeepsFirstPlaceAndLastValue() throws {
        // What a Python dict built by json.load does.
        let value = try parse(#"{"a": 1, "b": 2, "a": 3}"#)
        guard case let .object(pairs) = value else { Issue.record("not an object"); return }
        #expect(pairs.map(\.key) == ["a", "b"])
        #expect(value["a"] == .number("3"))
    }

    @Test func decodesEscapes() throws {
        #expect(try parse(#""tab\there \"q\" \u00e9 \ud83c\udf99 \/""#) == .string("tab\there \"q\" é 🎙 /"))
    }

    @Test func rejectsWhatPythonRejects() {
        for bad in ["{", "[1,]", "{\"a\" 1}", "01", "\"raw\u{01}control\"", "\u{FEFF}{}", "{} x", "\"\\u12G4\""] {
            #expect(throws: JSONParseError.self) { try parse(bad) }
        }
    }

    @Test func acceptsNaNAndInfinityLikePython() throws {
        #expect(try parse("[NaN, Infinity, -Infinity, -0, 1e5]") ==
            .array([.number("NaN"), .number("Infinity"), .number("-Infinity"), .number("-0"), .number("1e5")]))
    }

    @Test func pythonStrOfOddWordListEntries() throws {
        guard case let .array(items) = try parse(#"["x", 7, -0, 7.5, true, null, 1e2]"#) else {
            Issue.record("not an array")
            return
        }
        #expect(items.map(\.pythonString) == ["x", "7", "0", "7.5", "True", "None", "100.0"])
    }
}

struct SettingsTests {
    func settings(_ json: String) throws -> VoiceTypeSettings {
        VoiceTypeSettings.parse(try OrderedJSONParser.parse(Data(json.utf8)))
    }

    @Test func readsTheWordListAndCorrections() throws {
        let s = try settings(#"{"vocabulary": ["Convex", "Tapo"], "corrections": {"congress": "Convex"}, "other": 1}"#)
        #expect(s.vocabularyPrompt == "Convex, Tapo.")
        #expect(s.corrections.pairs.map(\.wrong) == ["congress"])
        #expect(s.corrections.pairs.map(\.right) == ["Convex"])
    }

    @Test func missingKeysGetPythonsDefaults() throws {
        let s = try settings("{}")
        #expect(s.vocabulary == VoiceTypeSettings.defaultVocabulary)
        #expect(s.corrections.pairs.map(\.wrong) == ["Q DA", "Kuda"])
        #expect(s.corrections.pairs.map(\.right) == ["CUDA", "CUDA"])
    }

    @Test func emptyOrNullMeansNone() throws {
        let s = try settings(#"{"vocabulary": null, "corrections": {}}"#)
        #expect(s.vocabularyPrompt == nil)
        #expect(s.corrections.pairs.isEmpty)
        #expect(try settings(#"{"vocabulary": []}"#).vocabularyPrompt == nil)
    }

    @Test func unreadableFileMeansDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-settings-\(UUID()).json")
        try Data("{not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(VoiceTypeSettings.load(from: url).vocabulary == VoiceTypeSettings.defaultVocabulary)
        #expect(VoiceTypeSettings.load(from: url.appendingPathExtension("missing")).corrections.pairs.count == 2)
    }

    @Test func pythonIteratesAStringWordListByCharacter() throws {
        #expect(try settings(#"{"vocabulary": "abA"}"#).vocabularyPrompt == "a, b.")
    }

    @Test func keysOnlyThePythonVersionUsedAreIgnored() throws {
        // Older settings.json files still have them. They stay in the file and change nothing.
        let old = #"""
        {"final_model": "large-v3-turbo", "stream_model": "small.en", "output_mode": "type", "formatter_enabled": true,
         "formatter_model": "qwen3", "formatter_system_prompt": {"odd": 1}, "vocabulary": ["Convex"], "corrections": {"congress": "Convex"}}
        """#
        let plain = #"{"vocabulary": ["Convex"], "corrections": {"congress": "Convex"}}"#
        #expect(try settings(old).vocabularyPrompt == settings(plain).vocabularyPrompt)
        #expect(try settings(old).corrections.pairs.map(\.wrong) == ["congress"])
        let file = SettingsFile(url: URL(fileURLWithPath: "/tmp/settings.json"), json: try OrderedJSONParser.parse(Data(old.utf8)))
        #expect(file.microphoneName == SettingsFile.defaultMicrophoneName)
        #expect(file.markerTimings == .accurate)
        #expect(file.json["formatter_model"] == .string("qwen3"))
    }

    @Test func nonStringCorrectionValuesAreSkipped() throws {
        let s = try settings(#"{"corrections": {"a": 1, "b": "B"}}"#)
        #expect(s.corrections.pairs.map(\.wrong) == ["b"])
    }
}
