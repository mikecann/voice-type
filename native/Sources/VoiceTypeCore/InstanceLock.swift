import Darwin
import Foundation

/// `voice-type.instance.lock` in the data folder, held by the copy of Voice Type Native that
/// dictates, so a second copy (one opened by hand, say) can't fight it over F12. The app
/// won't turn its keyboard tap on until it has the lock. It's an exclusive flock, so it goes
/// with the process however that ends, and the pid written inside says who has it.
public final class InstanceLock: @unchecked Sendable {
    public let url: URL
    private var fd: Int32 = -1
    private let lock = NSLock()

    public init(url: URL = VoiceTypePaths.dataDirectory.appendingPathComponent("voice-type.instance.lock")) {
        self.url = url
    }

    public var isHeld: Bool { lock.withLock { fd >= 0 } }

    /// Takes the lock without waiting. On success the file holds this process's pid.
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

    /// The pid written in the lock file, whoever holds it now.
    public func recordedPID() -> Int32? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Int32(PythonText.strip(String(decoding: data, as: UTF8.self)))
    }
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
}

/// Who the lock file says holds the lock, so a second copy of native can tell another
/// running copy (quit, or wait for it) from a pid that's someone else's.
public enum LockHolder: Equatable, Sendable {
    case nobody
    case native(pid: Int32)
    /// A pid that isn't Voice Type Native (or none), e.g. one left from an older process.
    case other(pid: Int32?)

    public static func identify(pid: Int32?, executablePath: (Int32) -> String? = ProcessLookup.executablePath) -> LockHolder {
        guard let pid, let path = executablePath(pid) else { return .other(pid: pid) }
        return isNativeExecutable(path) ? .native(pid: pid) : .other(pid: pid)
    }

    static func isNativeExecutable(_ path: String) -> Bool {
        path.hasSuffix("/Contents/MacOS/voice-type-native") || path.hasSuffix("/voice-type-native")
    }
}
