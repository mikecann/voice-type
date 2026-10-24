import Darwin
import Foundation

/// Python's `voice-type.instance.lock`, held by whichever Voice Type owns the hotkey.
///
/// voice-type.py takes an exclusive flock on it at import time and exits as a duplicate when
/// it can't, so native holding it is the backstop that stops a Python worker started by
/// mistake (from Spotlight, or its restart script) from fighting over F12. Native won't turn
/// its keyboard tap on until it has the lock.
///
/// Python also reads the pid written inside, and a heartbeat file's age: with a stale
/// heartbeat it tries to kill the pid, but only if that process's command line is Python's
/// own worker, which native's never is. Keeping the heartbeat fresh means Python just exits
/// quietly instead of logging that it found a wedged instance.
public final class InstanceLock: @unchecked Sendable {
    public let url: URL
    public let heartbeatURL: URL
    private var fd: Int32 = -1
    private let lock = NSLock()

    public init(url: URL = VoiceTypePaths.dataDirectory.appendingPathComponent("voice-type.instance.lock"),
                heartbeatURL: URL = VoiceTypePaths.dataDirectory.appendingPathComponent("voice-type.heartbeat")) {
        self.url = url
        self.heartbeatURL = heartbeatURL
    }

    public var isHeld: Bool { lock.withLock { fd >= 0 } }

    /// Takes the lock without waiting. On success the file holds this process's pid, as
    /// Python leaves it.
    public func tryAcquire(pid: Int32 = getpid()) -> Bool {
        lock.withLock {
            if fd >= 0 { return true }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let opened = open(url.path, O_RDWR | O_CREAT, 0o644)
            guard opened >= 0 else { return false }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                close(opened)
                return false
            }
            ftruncate(opened, 0)
            let text = Array(String(pid).utf8)
            _ = pwrite(opened, text, text.count, 0)
            fsync(opened)
            fd = opened
            return true
        }
    }

    public func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Refreshes the heartbeat Python checks, with `str(time.time())` in it as Python writes.
    public func touchHeartbeat(now: Date = Date()) {
        guard isHeld else { return }
        try? Data(String(now.timeIntervalSince1970).utf8).write(to: heartbeatURL)
    }

    /// The pid written in the lock file, whoever holds it now.
    public func recordedPID() -> Int32? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Int32(PythonText.strip(String(decoding: data, as: UTF8.self)))
    }

    /// Whether nobody holds the lock right now, without taking it or touching the pid in it.
    /// Only for the command line between stopping one app and starting the other: a Python
    /// worker that finds the lock taken, even for a moment, exits as a duplicate.
    public func isFree() -> Bool {
        if isHeld { return false }
        let opened = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard opened >= 0 else { return false }
        defer { close(opened) }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(opened, LOCK_UN)
        return true
    }
}

/// The lock as the native app's handover needs it, so the tests can stand in for it.
public protocol LockOwning: AnyObject {
    var holdsLock: Bool { get }
    func takeLock() -> Bool
    func releaseLock()
}

extension InstanceLock: LockOwning {
    public var holdsLock: Bool { isHeld }
    public func takeLock() -> Bool { tryAcquire() }
    public func releaseLock() { release() }
}

public enum ProcessLookup {
    /// The executable of a running process, or nil if there's no such process.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// A Voice Type Native app is running as `pid`. A pid in a status file can outlive its
    /// process and be reused by anything, so the executable is checked, not just kill(pid, 0).
    public static func isVoiceTypeNative(pid: Int32, executablePath: (Int32) -> String? = ProcessLookup.executablePath) -> Bool {
        guard pid > 0, pid != getpid(), let path = executablePath(pid) else { return false }
        return LockHolder.isNativeExecutable(path)
    }

    /// The process's command line, from ps. Nil if it has gone.
    public static func commandLine(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = PythonText.strip(String(decoding: data, as: UTF8.self))
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}

/// Who holds the lock, so a second copy of native can tell "Python is running" (wait for
/// it, or offer to switch) from "native is already running" (just quit).
public enum LockHolder: Equatable, Sendable {
    case nobody
    case native(pid: Int32)
    case python(pid: Int32?)

    public static func identify(pid: Int32?, executablePath: (Int32) -> String? = ProcessLookup.executablePath) -> LockHolder {
        guard let pid, let path = executablePath(pid) else { return .python(pid: pid) }
        return isNativeExecutable(path) ? .native(pid: pid) : .python(pid: pid)
    }

    static func isNativeExecutable(_ path: String) -> Bool {
        path.hasSuffix("/Contents/MacOS/voice-type-native") || path.hasSuffix("/voice-type-native")
    }
}

/// Finding and stopping whichever Voice Type process actually holds the lock, for switching.
/// The system one is SystemVoiceTypeProcesses; the tests use a fake.
public protocol VoiceTypeProcesses: AnyObject {
    /// Who the lock file says holds it (by the pid written inside; the lock may be free).
    func lockHolder() -> LockHolder
    func lockIsFree() -> Bool
    func isAlive(_ pid: Int32) -> Bool
    /// The process is Python Voice Type's worker (its command line runs voice-type.py).
    func isPythonWorker(_ pid: Int32) -> Bool
    func terminate(_ pid: Int32)
    func forceKill(_ pid: Int32)
}

public final class SystemVoiceTypeProcesses: VoiceTypeProcesses {
    private let lock: InstanceLock

    public init(lock: InstanceLock = InstanceLock()) { self.lock = lock }

    public func lockHolder() -> LockHolder { lock.recordedPID().map { LockHolder.identify(pid: $0) } ?? .nobody }
    public func lockIsFree() -> Bool { lock.isFree() }
    public func isAlive(_ pid: Int32) -> Bool { ProcessLookup.isAlive(pid: pid) }
    public func isPythonWorker(_ pid: Int32) -> Bool { ProcessLookup.commandLine(pid: pid)?.contains("voice-type.py") ?? false }
    public func terminate(_ pid: Int32) { kill(pid, SIGTERM) }
    public func forceKill(_ pid: Int32) { kill(pid, SIGKILL) }
}
