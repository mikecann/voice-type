import Foundation
import VoiceTypeCore

/// `/bin/launchctl` in this user's GUI domain.
public final class ProcessLaunchControl: LaunchControl {
    private let domain = "gui/\(getuid())"

    public init() {}

    @discardableResult
    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func require(_ arguments: [String]) throws {
        let (status, output) = run(arguments)
        guard status == 0 else {
            throw SwitchError("launchctl \(arguments.joined(separator: " ")) failed (\(status)): \(PythonText.strip(output))")
        }
    }

    public func isLoaded(_ label: String) -> Bool { run(["print", "\(domain)/\(label)"]).status == 0 }

    public func isRunning(_ label: String) -> Bool {
        let (status, output) = run(["print", "\(domain)/\(label)"])
        return status == 0 && output.contains("state = running")
    }

    /// Whether launchd is running the job or will start it again: running, not run yet, or
    /// last exited non-zero (KeepAlive's SuccessfulExit=false brings those back, after the
    /// throttle). A job that last exited 0 stays down.
    public func willRun(_ label: String) -> Bool {
        let (status, output) = run(["print", "\(domain)/\(label)"])
        return status == 0 && Self.willRun(inPrintOutput: output)
    }

    static func willRun(inPrintOutput output: String) -> Bool {
        if output.contains("state = running") { return true }
        guard let line = output.split(separator: "\n").first(where: { $0.contains("last exit code =") }) else { return true }
        let value = line.split(separator: "=", maxSplits: 1).last.map { PythonText.strip(String($0)) } ?? ""
        guard let code = Int(value.prefix { $0.isNumber || $0 == "-" }) else { return true }  // "(never exited)"
        return code != 0
    }

    /// print-disabled lists overrides as `"label" => disabled` (or `=> true` on older macOS).
    public func isDisabled(_ label: String) -> Bool {
        Self.isDisabled(label, inPrintDisabledOutput: run(["print-disabled", domain]).output)
    }

    static func isDisabled(_ label: String, inPrintDisabledOutput output: String) -> Bool {
        for line in output.split(separator: "\n") where line.contains("\"\(label)\"") {
            return line.contains("=> disabled") || line.contains("=> true")
        }
        return false
    }

    public func enable(_ label: String) throws { try require(["enable", "\(domain)/\(label)"]) }
    public func disable(_ label: String) throws { try require(["disable", "\(domain)/\(label)"]) }
    public func bootstrap(_ plist: URL) throws { try require(["bootstrap", domain, plist.path]) }
    public func bootout(_ label: String) throws { try require(["bootout", "\(domain)/\(label)"]) }

    public func kickstart(_ label: String, restart: Bool) throws {
        let (status, output) = run(["kickstart"] + (restart ? ["-k"] : []) + ["\(domain)/\(label)"])
        // Kickstarting a service that's already running isn't a failure.
        guard status == 0 || isRunning(label) else {
            throw SwitchError("launchctl kickstart \(label) failed (\(status)): \(PythonText.strip(output))")
        }
    }
}

/// Asks the Python app what it's doing, over the Unix socket voice_type_control.py serves in
/// the data folder. No answer means it isn't running (or is too wedged to be dictating).
public final class PythonControlSocket: PythonVoiceTypeProbe {
    let path: String

    public init(path: String = VoiceTypePaths.dataDirectory.appendingPathComponent("voice-type-control.sock").path) {
        self.path = path
    }

    public func activity() -> PeerActivity {
        guard let reply = request(Self.getState) else { return .notRunning }
        return PythonControlState.activity(fromReply: reply)
    }

    public func pauseIfIdle() -> PythonPause {
        guard let reply = request(Self.getState) else { return .notRunning }
        if case let .busy(what) = PythonControlState.activity(fromReply: reply) { return .busy(what) }
        // A Python too old to say isn't toggled blind.
        guard PythonControlState.enabled(fromReply: reply) == true else { return .alreadyPaused }
        // Straight after the reading: this round trip is the only gap.
        guard let toggled = request(Self.toggle) else { return .notRunning }
        if PythonControlState.enabled(fromReply: toggled) == true {
            // Someone else toggled it in between; once more pauses it.
            _ = request(Self.toggle)
        }
        return .paused
    }

    public func resume() {
        guard let reply = request(Self.getState), PythonControlState.enabled(fromReply: reply) == false else { return }
        _ = request(Self.toggle)
    }

    private static let getState = Data(#"{"command": "get_state"}"#.utf8)
    private static let toggle = Data(#"{"command": "toggle_enabled"}"#.utf8)

    func request(_ payload: Data, timeout: Double = 1.5) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }
        guard sent == payload.count else { return nil }
        shutdown(fd, SHUT_WR)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            reply.append(buffer, count: n)
        }
        return reply.isEmpty ? nil : reply
    }
}

/// Writes every thread's stack to a file with /usr/bin/sample before a watchdog exits, the
/// native stand-in for Python's faulthandler dump. Bounded, since it's run when something is
/// already stuck.
public enum HangReport {
    public static func capture(reason: String, log: (String) -> Void) {
        let stamp = Int(Date().timeIntervalSince1970)
        let file = LaunchAgents.logDirectory.appendingPathComponent("voice-type-native-hang-\(stamp).txt")
        log("Current thread: " + Thread.callStackSymbols.prefix(12).joined(separator: " | "))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "1", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate() }
            log("Thread dump written to \(file.path)")
        } catch {
            log("Thread dump failed: \(error.localizedDescription)")
        }
    }
}
