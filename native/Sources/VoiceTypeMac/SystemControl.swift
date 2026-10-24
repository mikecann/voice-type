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
            throw LaunchctlError("launchctl \(arguments.joined(separator: " ")) failed (\(status)): \(PythonText.strip(output))")
        }
    }

    public func isLoaded(_ label: String) -> Bool { run(["print", "\(domain)/\(label)"]).status == 0 }

    public func isRunning(_ label: String) -> Bool {
        let (status, output) = run(["print", "\(domain)/\(label)"])
        return status == 0 && output.contains("state = running")
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
    public func bootstrap(_ plist: URL) throws { try require(["bootstrap", domain, plist.path]) }

    public func kickstart(_ label: String, restart: Bool) throws {
        let (status, output) = run(["kickstart"] + (restart ? ["-k"] : []) + ["\(domain)/\(label)"])
        // Kickstarting a service that's already running isn't a failure.
        guard status == 0 || isRunning(label) else {
            throw LaunchctlError("launchctl kickstart \(label) failed (\(status)): \(PythonText.strip(output))")
        }
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
