import Foundation

/// settings.json, in the Python version's format: native reads the keys it needs, and when it
/// changes one it rewrites the file the way Python's _save_settings did, keeping every key it
/// doesn't know about (the Python version's own included) in its place.
///
/// Python wrote `json.dump(settings, f, indent=2)` (so non-ASCII is escaped) with no
/// trailing newline, to `settings.json.<pid>.tmp`, fsynced and renamed it. Native-only
/// settings live under "native".
public struct SettingsFile: Sendable {
    public var url: URL
    public private(set) var json: JSONValue

    public static let nativeKey = "native"

    /// What voice-type.py's _load_settings fills in for microphone_name.
    public static let defaultMicrophoneName = "Yeti Stereo Microphone"

    public init(url: URL, json: JSONValue) {
        self.url = url
        self.json = json
    }

    /// A missing or unreadable file reads as empty, as in Python, which logs and carries on.
    public static func load(from url: URL = VoiceTypePaths.settingsFile) -> SettingsFile {
        let json = (try? Data(contentsOf: url)).flatMap { try? OrderedJSONParser.parse($0) }
        if case .object? = json { return SettingsFile(url: url, json: json!) }
        return SettingsFile(url: url, json: .object([]))
    }

    public var dictation: VoiceTypeSettings { VoiceTypeSettings.parse(json) }

    /// The preferred input by name, "" for the system default. Python strips it.
    public var microphoneName: String {
        guard let value = json["microphone_name"] else { return Self.defaultMicrophoneName }
        return PythonText.strip(value.stringValue ?? "")
    }

    /// Off unless set, as in Python's setdefault.
    public var audioRecordingEnabled: Bool { json["audio_recording_enabled"]?.isTruthy ?? false }

    /// Drawing on screen while the key is held. On unless set.
    public var drawOnScreenEnabled: Bool { json["draw_on_screen_enabled"]?.isTruthy ?? true }

    /// The vocabulary as Python's `list(_settings.get("vocabulary", []))` would store it in a
    /// recording: the list itself when it's a list of strings.
    public var vocabularyForRecording: JSONValue {
        switch json["vocabulary"] {
        case let .array(items)?: return .array(items)
        case nil: return .strings(VoiceTypeSettings.defaultVocabulary)
        default: return .strings(dictation.vocabulary ?? [])
        }
    }

    public func native(_ key: String) -> JSONValue? { json[Self.nativeKey]?[key] }

    /// How screen marks' "[n]" markers are timed: `"native": {"marker_timings": "rough"}`
    /// uses the final pass's own token timestamps and never loads the second, 1 GB timing
    /// context; anything else means "accurate", the DTW timing pass.
    public enum MarkerTimings: String, Sendable { case accurate, rough }

    public var markerTimings: MarkerTimings {
        guard let value = native("marker_timings")?.stringValue else { return .accurate }
        return MarkerTimings(rawValue: PythonText.strip(value).lowercased()) ?? .accurate
    }

    // MARK: The settings window's edits

    /// The word list as the settings window edits it: what Whisper is primed with now.
    public var vocabularyWords: [String] { dictation.vocabulary ?? [] }

    /// Saves the word list, trimmed, without blanks or repeats, in the order given.
    public mutating func setVocabulary(_ words: [String]) {
        var seen = Set<String>()
        let cleaned = words.map { PythonText.strip($0) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        set("vocabulary", .strings(cleaned))
    }

    /// The corrections in the order they run, as the settings window edits them.
    public var correctionPairs: [(heard: String, typed: String)] {
        dictation.corrections.pairs.map { (heard: $0.wrong, typed: $0.right) }
    }

    /// Saves the corrections in the order given. Blank "heard" rows are dropped, and a
    /// repeated one keeps its first place, since a JSON object can only have each key once.
    public mutating func setCorrections(_ pairs: [(heard: String, typed: String)]) {
        var seen = Set<String>()
        var object: [(key: String, value: JSONValue)] = []
        for pair in pairs {
            let heard = PythonText.strip(pair.heard)
            guard !heard.isEmpty, seen.insert(heard).inserted else { continue }
            object.append((heard, .string(PythonText.strip(pair.typed))))
        }
        set("corrections", .object(object))
    }

    /// The settings window's word list edits, laid over the file as it is now: words it
    /// removed are taken out and words it added go on the end, so a word put in settings.json
    /// by hand (or by an agent) while the window was open isn't lost. With no change from
    /// outside, the window's list is saved as it is.
    public mutating func applyVocabularyEdit(from base: [String], to edited: [String]) {
        let current = vocabularyWords
        guard current != base else { return setVocabulary(edited) }
        let kept = Set(edited.map(PythonText.strip))
        let before = Set(base)
        let removed = before.subtracting(kept)
        let added = edited.map(PythonText.strip).filter { !before.contains($0) }
        setVocabulary(current.filter { !removed.contains($0) } + added)
    }

    /// The same for corrections, by what's heard: removed ones go, changed and new ones are
    /// set, and anything else in the file stays where it is.
    public mutating func applyCorrectionsEdit(from base: [(heard: String, typed: String)], to edited: [(heard: String, typed: String)]) {
        let current = correctionPairs
        let same = current.count == base.count && zip(current, base).allSatisfy { $0.heard == $1.heard && $0.typed == $1.typed }
        guard !same else { return setCorrections(edited) }
        let cleaned = edited.map { (heard: PythonText.strip($0.heard), typed: PythonText.strip($0.typed)) }.filter { !$0.heard.isEmpty }
        let before = Dictionary(base.map { ($0.heard, $0.typed) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(cleaned.map { ($0.heard, $0.typed) }, uniquingKeysWith: { first, _ in first })
        var result = current.filter { before[$0.heard] == nil || after[$0.heard] != nil }
            .map { pair in (heard: pair.heard, typed: before[pair.heard] != after[pair.heard] ? after[pair.heard] ?? pair.typed : pair.typed) }
        for pair in cleaned where before[pair.heard] != pair.typed && !result.contains(where: { $0.heard == pair.heard }) {
            result.append(pair)
        }
        setCorrections(result)
    }

    /// Keys only the Python version read: its model and mode choices and the formatter, which
    /// native dropped. Nothing reads them now.
    public static let retiredKeys = ["final_model", "stream_model", "output_mode", "formatter_enabled", "formatter_model", "formatter_system_prompt"]

    /// Removes the retired keys, returning which were there.
    @discardableResult
    public mutating func removeRetiredKeys() -> [String] {
        let present = Self.retiredKeys.filter { json[$0] != nil }
        for key in present { json.remove(key) }
        return present
    }

    public mutating func set(_ key: String, _ value: JSONValue) {
        json.set(key, value)
    }

    public mutating func setNative(_ key: String, _ value: JSONValue) {
        var native = json[Self.nativeKey] ?? .object([])
        if case .object = native {} else { native = .object([]) }
        native.set(key, value)
        json.set(Self.nativeKey, native)
    }

    /// The bytes Python's json.dump(settings, f, indent=2) writes.
    public var serialized: Data { Data(PythonJSON.dumps(json, indent: 2, ensureASCII: true).utf8) }

    public func save(pid: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = "\(url.path).\(pid).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = [UInt8](serialized)
        let ok = write(fd, bytes, bytes.count) == bytes.count && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw POSIXError(.EIO)
        }
    }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
