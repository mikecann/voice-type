import Foundation

/// Where Voice Type keeps its data: the folder the Python version used, so its settings,
/// recordings and history carry on.
public enum VoiceTypePaths {
    /// `$VOICE_TYPE_DATA_DIR`, or ~/Library/Application Support/Voice Type, as in voice-type.py.
    public static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["VOICE_TYPE_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice Type")
    }

    public static var settingsFile: URL { dataDirectory.appendingPathComponent("settings.json") }
    public static var recordingsDirectory: URL { dataDirectory.appendingPathComponent("recordings") }
    public static var defaultModel: URL {
        dataDirectory.appendingPathComponent("models/ggml-large-v3-turbo-q8_0.bin")
    }
}

/// The parts of settings.json the pipeline reads. Read-only: phase 1a never writes it.
public struct VoiceTypeSettings {
    /// The word list as voice-type.py iterates it.
    public var vocabulary: [String]?
    public var corrections: Corrections

    /// What voice-type.py fills in when settings.json lacks the keys.
    public static let defaultVocabulary = [
        "Convex", "Cannvas", "Claude", "Codex", "Tailscale", "Sammy Cam",
        "worktrees", "PR", "Slack", "Notion", "Cloudflare", "Vercel",
        "Supertonic", "Kokoro", "Tapo", "Parakeet", "Whisper",
    ]

    public init(vocabulary: [String]?, corrections: Corrections) {
        self.vocabulary = vocabulary
        self.corrections = corrections
    }

    public var vocabularyPrompt: String? { VocabularyPrompt.build(vocabulary) }

    /// Reads settings.json. A missing or unreadable file means the defaults, as in Python's
    /// _load_settings, which logs the error and carries on with an empty dict.
    public static func load(from url: URL = VoiceTypePaths.settingsFile) -> VoiceTypeSettings {
        guard let data = try? Data(contentsOf: url),
              let json = try? OrderedJSONParser.parse(data) else {
            return parse(.object([]))
        }
        return parse(json)
    }

    public static func parse(_ json: JSONValue) -> VoiceTypeSettings {
        // A top-level value that isn't an object would have crashed the Python version on startup.
        // Treat it like an empty file instead.
        let vocabulary: [String]?
        switch json["vocabulary"] {
        case nil:
            vocabulary = defaultVocabulary
        case let .array(items)?:
            vocabulary = items.map(\.pythonString)
        case let .string(s)?:
            // Python iterates a string one character at a time. Odd, but it's what it'd do.
            vocabulary = s.unicodeScalars.map { String($0) }
        case let .object(pairs)?:
            vocabulary = pairs.map(\.key)
        default:
            // null, false or 0 mean no words. Python would fail on any other number, so the
            // closest safe thing is no prompt.
            vocabulary = nil
        }

        let corrections: Corrections
        switch json["corrections"] {
        case nil:
            corrections = .pythonDefaults
        case let .object(pairs)?:
            // Python would fail the whole transcription on a non-string value. Skipping it
            // keeps the rest working.
            corrections = Corrections(pairs.compactMap { pair in
                pair.value.stringValue.map { (pair.key, $0) }
            })
        default:
            corrections = Corrections([])
        }
        return VoiceTypeSettings(vocabulary: vocabulary, corrections: corrections)
    }
}
