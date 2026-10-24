import Foundation

// How the app keeps itself alive without looping: a backoff on exit-75 restarts, a watchdog on
// the controller's queue, and the rules for when a copy of the app may take Python's lock.

/// The restarts native has made for failures (a watchdog, a hung Core Audio call, a model that
/// wouldn't load), in `native-restarts.json` in the data folder, so the next launch knows. A
/// restart someone asked for (`voice-type-native restart`, Try Again) isn't one, and the list
/// is cleared once the app has been ready for a minute.
public final class RestartHistory: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Seconds since 1970.
        public var at: Double
        public var reason: String

        public init(at: Double, reason: String) {
            self.at = at
            self.reason = reason
        }
    }

    public let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL { VoiceTypePaths.dataDirectory.appendingPathComponent("native-restarts.json") }

    public init(url: URL = RestartHistory.defaultURL) { self.url = url }

    /// Entries inside the backoff window, oldest first.
    public func recent(now: Date = Date()) -> [Entry] {
        lock.withLock { load().filter { now.timeIntervalSince1970 - $0.at < RestartBackoff.windowSeconds } }
    }

    public func record(_ reason: String, now: Date = Date()) {
        lock.withLock {
            var entries = load().filter { now.timeIntervalSince1970 - $0.at < RestartBackoff.windowSeconds }
            entries.append(Entry(at: now.timeIntervalSince1970, reason: reason))
            save(entries)
        }
    }

    public func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    private func load() -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? RecordingArchive.writeAtomic(data + Data("\n".utf8), to: url)
    }
}

/// What a fresh launch does after earlier failed ones. A fault that comes back every time (a
/// corrupt model makes whisper_init fail, say) used to relaunch every 10 s forever, flashing
/// the microphone dot for the readiness check and writing a thread dump each time. Now the
/// first restart is immediate (a one-off hang after a wake recovers at once), later ones wait
/// longer, and after five in half an hour the app stays up, says what went wrong, and leaves
/// the keyboard alone until someone fixes it and chooses Try Again.
public enum RestartBackoff {
    public static let windowSeconds = 30 * 60.0
    /// Failures in the window before it stops trying.
    public static let maxFailures = 5
    /// Seconds to wait before starting, by failures so far in the window (0, 1, 2, 3, 4).
    public static let delays: [Double] = [0, 0, 30, 120, 300]
    /// Thread dumps only for the first few failures in the window; the rest add nothing.
    public static let dumpThreadsUpTo = 2

    public enum Plan: Equatable, Sendable {
        case startNow
        /// Wait this long first, measured from the last failure.
        case wait(seconds: Double)
        case giveUp
    }

    public static func plan(_ recent: [RestartHistory.Entry], now: Date) -> Plan {
        guard recent.count < maxFailures else { return .giveUp }
        let delay = delays[min(recent.count, delays.count - 1)]
        guard delay > 0, let last = recent.last else { return .startNow }
        let remaining = delay - (now.timeIntervalSince1970 - last.at)
        return remaining > 0 ? .wait(seconds: remaining) : .startNow
    }

    /// What the menu and the status file say while waiting or after giving up.
    public static func message(_ plan: Plan, recent: [RestartHistory.Entry]) -> String {
        let last = recent.last?.reason ?? "unknown"
        let count = recent.count
        switch plan {
        case .startNow: return ""
        case let .wait(seconds):
            return "Restarted \(count) times in \(Int(windowSeconds / 60)) min; trying again in \(Int(seconds.rounded(.up)))s. Last: \(last)"
        case .giveUp:
            return "Stopped after \(count) restarts in \(Int(windowSeconds / 60)) min: \(last). Fix that, then choose Try Again."
        }
    }
}

/// Notices a serial queue that has stopped running work. Every `check()` sends a ping through
/// the queue; one still waiting after `timeout` means the queue is stuck (a Core Audio call
/// that never returned, say) and `onStall` runs once. The controller's queue holds the hotkey,
/// so a stuck one would swallow F12 and Right Control with nothing happening.
public final class StallDetector: @unchecked Sendable {
    private let timeout: Double
    private let now: () -> Double
    private let ping: (@escaping @Sendable () -> Void) -> Void
    private let onStall: (Double) -> Void
    private let lock = NSLock()
    private var outstanding: Double?
    private var fired = false

    public init(timeout: Double, now: @escaping () -> Double, ping: @escaping (@escaping @Sendable () -> Void) -> Void, onStall: @escaping (Double) -> Void) {
        self.timeout = timeout
        self.now = now
        self.ping = ping
        self.onStall = onStall
    }

    public func check() {
        enum Step { case nothing, send, stall(Double) }
        let t = now()
        let step = lock.withLock { () -> Step in
            if let sent = outstanding {
                guard !fired, t - sent > timeout else { return .nothing }
                fired = true
                return .stall(t - sent)
            }
            outstanding = t
            return .send
        }
        switch step {
        case .nothing: break
        case .send: ping { [weak self] in self?.answered() }
        case let .stall(seconds): onStall(seconds)
        }
    }

    private func answered() { lock.withLock { outstanding = nil } }
}

/// When a copy of the native app may take Python's lock (and so the hotkey).
///
/// Only one native copy should ever dictate: launchd's. One opened by hand (Finder, Spotlight,
/// the first-run step) used to poll for the lock every second while Python held it, so after a
/// wake, when Python exits 75 and relaunches, it could grab the lock in the gap; Python's new
/// worker then saw a fresh heartbeat and exited 0, which its KeepAlive doesn't restart, leaving
/// Python dead while its agent was still the enabled one. So a hand-opened copy never takes the
/// lock when the LaunchAgent is installed: with native chosen it starts launchd's copy and
/// quits; with Python chosen it's just the permissions window and the switch. And launchd's
/// copy doesn't take the lock while Python's agent is still enabled and launchd is running it
/// or bringing it back, since that Python is the one in use.
public enum LockPolicy {
    public struct Situation: Equatable, Sendable {
        /// Started by launchd from native's agent.
        public var supervised: Bool
        /// A hand-opened copy relaunching itself after exiting 75 (only without an agent).
        public var relaunched: Bool
        public var nativeAgentInstalled: Bool
        public var nativeAgentEnabled: Bool
        /// Python's agent is enabled and launchd is running it or will bring it back.
        public var pythonAgentActive: Bool
        public var holder: LockHolder
        public var holderAlive: Bool
        public var ownPID: Int32

        public init(supervised: Bool, relaunched: Bool, nativeAgentInstalled: Bool, nativeAgentEnabled: Bool, pythonAgentActive: Bool,
                    holder: LockHolder, holderAlive: Bool, ownPID: Int32) {
            self.supervised = supervised
            self.relaunched = relaunched
            self.nativeAgentInstalled = nativeAgentInstalled
            self.nativeAgentEnabled = nativeAgentEnabled
            self.pythonAgentActive = pythonAgentActive
            self.holder = holder
            self.holderAlive = holderAlive
            self.ownPID = ownPID
        }
    }

    public enum Plan: Equatable, Sendable {
        /// Try for the lock now.
        case take
        /// Look again in a moment without trying for it.
        case wait(String)
        /// Another native copy has it; this one makes way.
        case quit(String)
        /// Hand-opened while native is the chosen app: start launchd's copy, then quit.
        case startAgentAndQuit
        /// Hand-opened while Python is the chosen app: permissions and the switch only.
        case uiOnly
    }

    public static func plan(_ s: Situation) -> Plan {
        if case let .native(pid) = s.holder, pid != s.ownPID, s.holderAlive {
            if s.supervised || s.relaunched {
                // launchd's copy never quits here (KeepAlive wouldn't bring it back after 0),
                // and a relaunch waits for the copy it replaced to finish exiting.
                return .wait("Another Voice Type Native (pid \(pid)) holds voice-type.instance.lock; waiting for it to quit.")
            }
            return .quit("Voice Type Native is already running (pid \(pid)); quitting this copy.")
        }
        if !s.supervised && !s.relaunched && s.nativeAgentInstalled {
            return s.nativeAgentEnabled ? .startAgentAndQuit : .uiOnly
        }
        if s.supervised && s.pythonAgentActive {
            return .wait("Python Voice Type's LaunchAgent is still enabled, so it keeps the hotkey. Use Switch to Voice Type Native to take over.")
        }
        return .take
    }
}
