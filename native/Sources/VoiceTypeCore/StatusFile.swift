import Foundation

/// `native-status.json` in the data folder: what the running app is doing, for the command
/// line (`status`, `restart`) and anything else that wants to know. Rewritten atomically
/// whenever something changes.
public struct NativeStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    /// starting, idle, recording, finalising, waiting_for_lock (another copy has it; only in
    /// the menu, since the file is that copy's), waiting_for_permission, needs_model, stopping, retrying (backing off after restarts),
    /// needs_attention (gave up after too many restarts), stopped
    public var state: String
    public var message: String
    public var enabled: Bool
    public var modelStatus: String
    public var hotkeyListener: String
    /// Holds voice-type.instance.lock, so this is the copy that dictates.
    public var holdsLock: Bool
    public var microphone: String
    public var preferredMicrophone: String
    public var finalizeInFlight: Bool
    public var permissions: [String: String]
    /// NSPasteboard.accessBehavior for the general pasteboard: default, ask, always_allow or
    /// always_deny. macOS 26 can ask before letting an app read the clipboard.
    public var pasteboardAccess: String
    public var lastDictation: LastDictation?
    public var version: String
    public var updatedAt: String

    public struct LastDictation: Codable, Equatable, Sendable {
        public var at: String
        public var status: String
        public var seconds: Double
        public var words: Int
        public var landed: Bool?

        public init(at: String, status: String, seconds: Double, words: Int, landed: Bool?) {
            self.at = at
            self.status = status
            self.seconds = seconds
            self.words = words
            self.landed = landed
        }
    }

    public init(pid: Int32, state: String, message: String = "", enabled: Bool = true, modelStatus: String = "not-started",
                hotkeyListener: String = "not-started", holdsLock: Bool = false, microphone: String = "",
                preferredMicrophone: String = "", finalizeInFlight: Bool = false, permissions: [String: String] = [:],
                pasteboardAccess: String = "unknown", lastDictation: LastDictation? = nil, version: String = "", updatedAt: String = "") {
        self.pid = pid
        self.state = state
        self.message = message
        self.enabled = enabled
        self.modelStatus = modelStatus
        self.hotkeyListener = hotkeyListener
        self.holdsLock = holdsLock
        self.microphone = microphone
        self.preferredMicrophone = preferredMicrophone
        self.finalizeInFlight = finalizeInFlight
        self.permissions = permissions
        self.pasteboardAccess = pasteboardAccess
        self.lastDictation = lastDictation
        self.version = version
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case pid, state, message, enabled, permissions, version
        case modelStatus = "model_status"
        case hotkeyListener = "hotkey_listener"
        // Named from when the lock was shared with the Python version. Kept, so a running
        // app and a newer command line (the build script's restart) still read each other.
        case holdsLock = "holds_python_lock"
        case microphone
        case preferredMicrophone = "preferred_microphone"
        case finalizeInFlight = "finalize_in_flight"
        case pasteboardAccess = "pasteboard_access"
        case lastDictation = "last_dictation"
        case updatedAt = "updated_at"
    }

    public static var defaultURL: URL { VoiceTypePaths.dataDirectory.appendingPathComponent("native-status.json") }

    /// Ready for a dictation, which is what `restart` waits for.
    public var isReady: Bool {
        state == "idle" && modelStatus == "ready" && hotkeyListener == "event-tap" && holdsLock
    }

    /// Mid-dictation, so restarting has to wait.
    public var isBusy: Bool { state == "recording" || state == "finalising" || finalizeInFlight }

    public func write(to url: URL = NativeStatus.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RecordingArchive.writeAtomic(try encoder.encode(self) + Data("\n".utf8), to: url)
    }

    public static func read(from url: URL = NativeStatus.defaultURL) -> NativeStatus? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(NativeStatus.self, from: $0) }
    }
}

/// The app's log, `~/Library/Logs/Voice Type/voice-type-native.log`, in voice-type.py's
/// format ("YYYY-MM-DD HH:MM:SS  message"). Python rotated it only at startup, which was enough
/// when every wake restarted the process; native runs for weeks, so it also rotates as it
/// goes: past 1 MB it keeps the last 2,000 lines. Writes go through one serial queue, and
/// nothing on the event tap's thread ever logs.
///
/// It only echoes to stderr when that's a terminal. Under launchd stderr is native-launchd.log,
/// and copying every line there doubled the log into a file nothing rotated.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "voice-type.log")
    private var handle: FileHandle?
    private let echo: Bool
    private let maxBytes: Int
    private let keepLines: Int
    private var size = 0

    public static var defaultURL: URL { LaunchAgents.logDirectory.appendingPathComponent("voice-type-native.log") }
    public static let defaultMaxBytes = 1_048_576
    public static let defaultKeepLines = 2_000

    public init(url: URL = LogFile.defaultURL, echoToStderr: Bool = isatty(STDERR_FILENO) == 1, maxBytes: Int = LogFile.defaultMaxBytes,
                keepLines: Int = LogFile.defaultKeepLines) {
        self.url = url
        self.echo = echoToStderr
        self.maxBytes = maxBytes
        self.keepLines = keepLines
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        Self.rotate(url, maxBytes: maxBytes, keepLines: keepLines)
        open()
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    static func rotate(_ url: URL, maxBytes: Int, keepLines: Int) {
        guard let text = trimmed(url, maxBytes: maxBytes, keepLines: keepLines) else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The file's last `keepLines` lines under Python's rotation marker, or nil if it's
    /// still under `maxBytes`.
    static func trimmed(_ url: URL, maxBytes: Int, keepLines: Int) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let all = lines.last == "" ? lines.dropLast() : lines[...]
        let kept = all.suffix(keepLines)
        return "[log rotated \u{2014} kept last \(keepLines) of \(all.count) lines]\n" + kept.joined(separator: "\n") + "\n"
    }

    /// Trims a log another process writes to, launchd's for this app's stdout and stderr, in
    /// place: the same file, so launchd's open descriptor (which appends) carries on into it.
    public static func trimInPlace(_ url: URL, maxBytes: Int = LogFile.defaultMaxBytes, keepLines: Int = LogFile.defaultKeepLines) {
        guard let text = trimmed(url, maxBytes: maxBytes, keepLines: keepLines), let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: Data(text.utf8))
    }

    public func log(_ message: String) {
        let line = Data((Self.timestamp(Date()) + "  " + message + "\n").utf8)
        queue.async { [self] in
            handle?.write(line)
            size += line.count
            if echo { FileHandle.standardError.write(line) }
            if size >= maxBytes {
                try? handle?.close()
                Self.rotate(url, maxBytes: maxBytes, keepLines: keepLines)
                open()
            }
        }
    }

    /// Waits for queued lines, before the process exits.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // DateFormatter is thread-safe for formatting.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String { formatter.string(from: date) }
}
