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

    /// Read now so phase 2 can follow it; native doesn't draw yet.
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
