import Foundation

/// `native-status.json` in the data folder: what the running app is doing, for the command
/// line (`status`, `restart`, `switch`) and anything else that wants to know without a
/// socket. Rewritten atomically whenever something changes.
public struct NativeStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    /// starting, idle, recording, finalising, waiting_for_python, waiting_for_permission,
    /// needs_model, stopping, retrying (backing off after restarts), needs_attention (gave up
    /// after too many restarts), stopped
    public var state: String
    public var message: String
    public var enabled: Bool
    public var modelStatus: String
    public var hotkeyListener: String
    public var holdsPythonLock: Bool
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
    /// Set when a hand-over to Python that `switch python` asked for didn't happen.
    public var handoverFailure: HandoverFailure?

    public struct HandoverFailure: Codable, Equatable, Sendable {
        /// Seconds since 1970, so the command line can tell it's about its own request.
        public var at: Double
        public var message: String

        public init(at: Double, message: String) {
            self.at = at
            self.message = message
        }
    }

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
                hotkeyListener: String = "not-started", holdsPythonLock: Bool = false, microphone: String = "",
                preferredMicrophone: String = "", finalizeInFlight: Bool = false, permissions: [String: String] = [:],
                pasteboardAccess: String = "unknown", lastDictation: LastDictation? = nil, version: String = "", updatedAt: String = "") {
        self.pid = pid
        self.state = state
        self.message = message
        self.enabled = enabled
        self.modelStatus = modelStatus
        self.hotkeyListener = hotkeyListener
        self.holdsPythonLock = holdsPythonLock
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
        case holdsPythonLock = "holds_python_lock"
        case microphone
        case preferredMicrophone = "preferred_microphone"
        case finalizeInFlight = "finalize_in_flight"
        case pasteboardAccess = "pasteboard_access"
        case lastDictation = "last_dictation"
        case updatedAt = "updated_at"
        case handoverFailure = "handover_failure"
    }

    public static var defaultURL: URL { VoiceTypePaths.dataDirectory.appendingPathComponent("native-status.json") }

    /// Ready for a dictation, which is what `restart` waits for.
    public var isReady: Bool {
        state == "idle" && modelStatus == "ready" && hotkeyListener == "event-tap" && holdsPythonLock
    }

    /// Mid-dictation, so switching or restarting has to wait.
    public var isBusy: Bool { state == "recording" || state == "finalising" || finalizeInFlight }

    public func write(to url: URL = NativeStatus.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RecordingArchive.writeAtomic(try encoder.encode(self) + Data("\n".utf8), to: url)
    }

    public static func read(from url: URL = NativeStatus.defaultURL) -> NativeStatus? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(NativeStatus.self, from: $0) }
    }

    /// What the file says the app is doing, or not running if its pid has gone (or is now
    /// some other program's).
    public static func activity(from url: URL = NativeStatus.defaultURL, isAlive: (Int32) -> Bool = { ProcessLookup.isVoiceTypeNative(pid: $0) }) -> PeerActivity {
        guard let status = read(from: url), status.state != "stopped", isAlive(status.pid) else { return .notRunning }
        return status.isBusy ? .busy(status.state) : .idle
    }
}

/// The running native app as the command line's switching sees it: its status file, checked
/// against the process, and SIGUSR2 to ask it to hand over to Python itself.
public final class NativeStatusProbe: NativeAppProbe {
    let url: URL
    let isNative: (Int32) -> Bool

    public init(url: URL = NativeStatus.defaultURL, isNative: @escaping (Int32) -> Bool = { ProcessLookup.isVoiceTypeNative(pid: $0) }) {
        self.url = url
        self.isNative = isNative
    }

    public func runningPID() -> Int32? {
        guard let status = NativeStatus.read(from: url), status.state != "stopped", isNative(status.pid) else { return nil }
        return status.pid
    }

    public func activity() -> PeerActivity { NativeStatus.activity(from: url, isAlive: isNative) }

    public func requestHandover(pid: Int32) { kill(pid, SIGUSR2) }

    public func handoverFailure(pid: Int32, since: Date) -> String? {
        guard let status = NativeStatus.read(from: url), status.pid == pid, let failure = status.handoverFailure,
              failure.at >= since.timeIntervalSince1970 - 1 else { return nil }
        return failure.message
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
