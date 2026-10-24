import Foundation

// Only one Voice Type can own the hotkey, so switching flips which LaunchAgent launchd runs.
//
// Each app has its own agent in ~/Library/LaunchAgents. The one not in use is booted out and
// disabled with `launchctl disable`, which persists across logins, so exactly one starts at
// login. The instance lock is the backstop if both ever run.
//
// A switch never kills a dictation it can see. The app being switched away from stops taking
// new ones first. Native does it itself, from its controller's queue, where a key-down can't
// slip in. Python is paused through its control socket the moment it reads idle, so the only
// gap is one socket round trip (its control interface has no "pause if idle" in one step).
// Then the switch waits for a dictation still finishing, checks again right before stopping
// it, and stops whichever process holds the lock, including one launchd didn't start. If
// starting the other app fails, everything goes back the way it was, so the working app is
// never left off.

public enum LaunchAgents {
    public static let pythonLabel = "com.mikerosoft.voice-type"
    public static let nativeLabel = "com.mikerosoft.voice-type-native"
    public static let nativeBundleID = "com.mikerosoft.voice-type-native"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    public static var pythonPlist: URL { directory.appendingPathComponent("\(pythonLabel).plist") }
    public static var nativePlist: URL { directory.appendingPathComponent("\(nativeLabel).plist") }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Voice Type")
    }

    /// Native's agent. KeepAlive on unsuccessful exit restarts it after a crash or a watchdog
    /// (which exits 75), but not after Quit (exit 0). Python's agent throttles restarts to
    /// 30 s; native's are rarer and a wake no longer restarts it, so 10 s (launchd's default)
    /// is plenty. AssociatedBundleIdentifiers lets Login Items show the app's name.
    public static func nativePlistContents(executable: String, logDirectory: URL = logDirectory) -> String {
        let log = logDirectory.appendingPathComponent("native-launchd.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(nativeLabel))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(xmlEscape(executable))</string>
          </array>
          <key>AssociatedBundleIdentifiers</key>
          <string>\(xmlEscape(nativeBundleID))</string>
          <key>StandardOutPath</key>
          <string>\(xmlEscape(log))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscape(log))</string>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
        </dict>
        </plist>

        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// `launchctl` in the user's GUI domain.
public protocol LaunchControl: AnyObject {
    func isLoaded(_ label: String) -> Bool
    func isDisabled(_ label: String) -> Bool
    func enable(_ label: String) throws
    func disable(_ label: String) throws
    func bootstrap(_ plist: URL) throws
    func bootout(_ label: String) throws
    /// `kickstart`, with `-k` when `restart` is set.
    func kickstart(_ label: String, restart: Bool) throws
}

/// Whether the other app is in the middle of a dictation.
public enum PeerActivity: Equatable, Sendable {
    case notRunning
    case idle
    case busy(String)
}

/// Asks the Python app over its control socket. Python's ui_state is "recording" while the
/// key is held, and finalize_in_flight stays true until its paste is done.
public protocol PythonVoiceTypeProbe: AnyObject {
    func activity() -> PeerActivity
    /// Reads Python's state and, if it's idle and taking dictations, pauses it straight away
    /// with toggle_enabled (voice-type.py then ignores key-downs). The pause follows the
    /// reading at once, so a key-down can only slip in during one socket round trip. While
    /// paused its ui_state reads "disabled" whatever it's doing, so afterwards only
    /// finalize_in_flight shows a dictation.
    func pauseIfIdle() -> PythonPause
    /// Undoes pauseIfIdle.
    func resume()
}

public enum PythonPause: Equatable, Sendable {
    case paused
    /// Paused already (from its own menu), so it takes no dictations; left that way.
    case alreadyPaused
    case busy(String)
    case notRunning
}

/// The running native app, for switching from the command line.
public protocol NativeAppProbe: AnyObject {
    /// The pid of a running Voice Type Native from its status file, checked to really be it.
    func runningPID() -> Int32?
    func activity() -> PeerActivity
    /// Asks it to switch to Python itself (SIGUSR2): it stops taking dictations straight
    /// away, finishes one that's running, then hands over and quits.
    func requestHandover(pid: Int32)
    /// Why a hand-over asked for at `since` didn't happen, if the app said so.
    func handoverFailure(pid: Int32, since: Date) -> String?
}

public enum PythonControlState {
    /// Reads a get_state reply from voice_type_control.py.
    public static func activity(fromReply data: Data) -> PeerActivity {
        guard let reply = try? OrderedJSONParser.parse(data), let state = reply["state"] else { return .idle }
        if state["finalize_in_flight"]?.isTruthy == true { return .busy("finishing a dictation") }
        if state["ui_state"]?.stringValue == "recording" { return .busy("recording") }
        return .idle
    }

    /// Whether Python is taking dictations, from a get_state (or command) reply.
    public static func enabled(fromReply data: Data) -> Bool? {
        guard let reply = try? OrderedJSONParser.parse(data), let state = reply["state"], let enabled = state["enabled"] else { return nil }
        return enabled.isTruthy
    }
}

public struct SwitchError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Checks a LaunchAgent before a switch relies on it: a plist that's there but broken would
/// only fail at bootstrap, after the other app had been stopped. Nil when it's fine.
public enum LaunchAgentCheck {
    public static func problem(with url: URL, label: String, fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "\(url.path) is missing" }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "\(url.path) isn't a valid property list"
        }
        guard plist["Label"] as? String == label else { return "\(url.path) isn't the agent for \(label)" }
        guard let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String else {
            return "\(url.path) has no program to run"
        }
        guard fileExists(program) else { return "\(url.path) runs \(program), which isn't there" }
        return nil
    }
}

public final class Switcher {
    private let launch: LaunchControl
    private let python: PythonVoiceTypeProbe
    private let native: NativeAppProbe
    private let processes: VoiceTypeProcesses
    private let pythonPlist: URL
    private let nativePlist: URL
    private let checkPlist: (URL, String) -> String?
    private let sleep: (Double) -> Void
    private let now: () -> Double
    private let wallClock: () -> Date
    private let say: (String) -> Void

    private let py = LaunchAgents.pythonLabel
    private let nat = LaunchAgents.nativeLabel

    /// Dictations are capped at 120 s and finalisation gets a little more.
    public static let busyWaitSeconds = 150.0
    /// How long the native app gets to finish a dictation and hand over by itself.
    public static let handoverWaitSeconds = busyWaitSeconds + 30
    /// How long a stopped process gets to exit before it's killed: longer than the 15 s
    /// native gives a dictation on SIGTERM. Python exits on SIGTERM straight away.
    public static let exitWaitSeconds = 20.0

    public init(launch: LaunchControl, python: PythonVoiceTypeProbe, native: NativeAppProbe, processes: VoiceTypeProcesses,
                pythonPlist: URL = LaunchAgents.pythonPlist, nativePlist: URL = LaunchAgents.nativePlist,
                checkPlist: @escaping (URL, String) -> String? = { LaunchAgentCheck.problem(with: $0, label: $1) },
                sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                wallClock: @escaping () -> Date = Date.init,
                say: @escaping (String) -> Void) {
        self.launch = launch
        self.python = python
        self.native = native
        self.processes = processes
        self.pythonPlist = pythonPlist
        self.nativePlist = nativePlist
        self.checkPlist = checkPlist
        self.sleep = sleep
        self.now = now
        self.wallClock = wallClock
        self.say = say
    }

    /// What launchd had before a switch, so a failed one can put it back.
    private struct Agents {
        var pythonDisabled: Bool
        var pythonLoaded: Bool
        var nativeDisabled: Bool
        var nativeLoaded: Bool
    }

    private func agents() -> Agents {
        Agents(pythonDisabled: launch.isDisabled(py), pythonLoaded: launch.isLoaded(py),
               nativeDisabled: launch.isDisabled(nat), nativeLoaded: launch.isLoaded(nat))
    }

    // MARK: To native

    /// Hands the hotkey to native. `fromNativeApp` is set when launchd's native copy asks
    /// itself (it's running, waiting for the lock); it then mustn't be restarted.
    public func switchToNative(fromNativeApp: Bool = false) throws {
        try requireAgent(nativePlist, label: nat, fix: "Run native/scripts/build-app.sh first.")
        let before = agents()
        var paused = false
        do {
            // Pause it the moment it's idle: no new dictations on Python from here.
            let deadline = now() + Self.busyWaitSeconds
            var announced = false
            pausing: while true {
                switch python.pauseIfIdle() {
                case .paused:
                    paused = true
                    break pausing
                case .alreadyPaused, .notRunning:
                    break pausing
                case let .busy(what):
                    if !announced {
                        say("Waiting for Python Voice Type to finish (\(what))...")
                        announced = true
                    }
                    guard now() < deadline else { throw SwitchError("Python Voice Type is still busy (\(what)); try again in a moment.") }
                    sleep(0.25)
                }
            }
            // Only a dictation that began in the round trip could still be finishing.
            try waitUntilIdle(name: "Python Voice Type", activity: python.activity)
            say("Stopping Python Voice Type...")
            try launch.disable(py)
            // Again right before stopping it, in case the pause didn't take (an older Python,
            // or one that didn't answer).
            try waitUntilIdle(name: "Python Voice Type", activity: python.activity)
            if launch.isLoaded(py) { try launch.bootout(py) }
            // One started by hand or from Spotlight isn't launchd's, so bootout missed it.
            try stopLockHolder(native: false)
            say("Starting Voice Type Native...")
            try launch.enable(nat)
            if launch.isLoaded(nat) {
                // Already loaded (it may be waiting for Python's lock, which it now gets).
                if !fromNativeApp { try launch.kickstart(nat, restart: false) }
            } else {
                try launch.bootstrap(nativePlist)
            }
        } catch {
            let undo = restorePython(before, paused: paused)
            throw SwitchError(Self.failure("switch to Voice Type Native", error, undo: undo, keeps: "Python Voice Type"))
        }
    }

    /// Puts Python back as it was: its agent enabled and started again if it was, native's
    /// disabled and stopped again if it was, and Python's dictation resumed.
    private func restorePython(_ before: Agents, paused: Bool) -> [String] {
        var problems: [String] = []
        func attempt(_ what: String, _ work: () throws -> Void) {
            do { try work() } catch { problems.append("\(what): \(error.localizedDescription)") }
        }
        if before.nativeDisabled && !launch.isDisabled(nat) { attempt("disabling native's agent again") { try launch.disable(nat) } }
        if !before.nativeLoaded && launch.isLoaded(nat) { attempt("stopping native's agent again") { try launch.bootout(nat) } }
        if !before.pythonDisabled && launch.isDisabled(py) { attempt("enabling Python's agent again") { try launch.enable(py) } }
        if before.pythonLoaded && !launch.isLoaded(py) { attempt("starting Python again") { try launch.bootstrap(pythonPlist) } }
        if paused { python.resume() }
        return problems
    }

    // MARK: To Python, from the command line

    /// Hands the hotkey back to Python from the command line. A running native app is asked
    /// to do it itself, since it can stop taking dictations without a gap; if it isn't
    /// running, or doesn't answer, it's done from here.
    public func switchToPython() throws {
        try requireAgent(pythonPlist, label: py, fix: "Run setup_mac.sh in the repo.")
        if let pid = native.runningPID() {
            let asked = wallClock()
            if case let .busy(what) = native.activity() { say("Waiting for Voice Type Native to finish (\(what))...") }
            native.requestHandover(pid: pid)
            let deadline = now() + Self.handoverWaitSeconds
            while processes.isAlive(pid) && now() < deadline {
                if let why = native.handoverFailure(pid: pid, since: asked) {
                    throw SwitchError("Voice Type Native didn't switch to Python: \(why). It's still running.")
                }
                sleep(0.25)
            }
            if !processes.isAlive(pid) && launch.isDisabled(nat) {
                // It switched. Make sure Python really is on its way.
                if launch.isDisabled(py) || !launch.isLoaded(py) { try startPython() }
                return
            }
            say(processes.isAlive(pid) ? "Voice Type Native didn't hand over in time; stopping it." : "Voice Type Native quit without switching; finishing the switch.")
        }
        let before = agents()
        do {
            say("Stopping Voice Type Native...")
            try launch.disable(nat)
            if launch.isLoaded(nat) { try launch.bootout(nat) }
            // A copy opened by hand that took the lock isn't launchd's either.
            try stopLockHolder(native: true)
            try startPython()
        } catch {
            let undo = restoreNative(before)
            throw SwitchError(Self.failure("switch to Python Voice Type", error, undo: undo, keeps: "Voice Type Native"))
        }
    }

    private func restoreNative(_ before: Agents) -> [String] {
        var problems: [String] = []
        func attempt(_ what: String, _ work: () throws -> Void) {
            do { try work() } catch { problems.append("\(what): \(error.localizedDescription)") }
        }
        if before.pythonDisabled && !launch.isDisabled(py) { attempt("disabling Python's agent again") { try launch.disable(py) } }
        if !before.pythonLoaded && launch.isLoaded(py) { attempt("stopping Python again") { try launch.bootout(py) } }
        if !before.nativeDisabled && launch.isDisabled(nat) { attempt("enabling native's agent again") { try launch.enable(nat) } }
        if before.nativeLoaded && !launch.isLoaded(nat) { attempt("starting native again") { try launch.bootstrap(nativePlist) } }
        return problems
    }

    // MARK: To Python, from the native app itself

    /// Whether the app's own switch can go ahead, checked before it turns its tap off.
    public func checkCanSwitchToPython() throws {
        try requireAgent(pythonPlist, label: py, fix: "Run setup_mac.sh in the repo.")
    }

    /// The native app's own switch, once its controller is idle and its tap is off. It
    /// disables itself so it doesn't come back at login, lets go of the lock so Python can
    /// take it, then starts Python. The app quits after this returns; exiting 0 doesn't
    /// trigger KeepAlive. If Python doesn't start, launchd is put back as it was and this
    /// throws; the caller takes the lock back and turns its tap on again.
    public func switchToPythonFromNativeApp(releaseLock: () -> Void) throws {
        try checkCanSwitchToPython()
        let before = agents()
        do {
            try launch.disable(nat)
            releaseLock()
            try startPython()
        } catch {
            let undo = restoreNative(before)
            throw SwitchError(Self.failure("switch to Python Voice Type", error, undo: undo, keeps: "Voice Type Native"))
        }
    }

    /// After a failed hand-over found Python holding the lock anyway: it did start, so leave
    /// it in charge and keep native off at login.
    public func leavePythonInCharge() {
        try? launch.disable(nat)
        try? launch.enable(py)
    }

    // MARK: Pieces

    private func requireAgent(_ url: URL, label: String, fix: String) throws {
        if let problem = checkPlist(url, label) { throw SwitchError("Can't switch: \(problem). \(fix)") }
    }

    private func startPython() throws {
        say("Starting Python Voice Type...")
        try launch.enable(py)
        if launch.isLoaded(py) {
            try launch.kickstart(py, restart: false)
        } else {
            try launch.bootstrap(pythonPlist)
        }
    }

    /// Stops the process holding the lock if it's the side being switched away from and
    /// launchd didn't stop it, then checks the lock is free. Python's is stopped with SIGTERM,
    /// which voice-type.py exits on; it's already paused and idle by now.
    private func stopLockHolder(native nativeSide: Bool) throws {
        let holder = processes.lockHolder()
        var stopping: Int32?
        switch holder {
        case let .native(pid) where nativeSide && processes.isAlive(pid): stopping = pid
        case let .python(pid?) where !nativeSide && processes.isAlive(pid) && processes.isPythonWorker(pid): stopping = pid
        default: break
        }
        if let pid = stopping {
            say("Stopping the \(nativeSide ? "Voice Type Native" : "Python Voice Type") launchd didn't start (pid \(pid))...")
            processes.terminate(pid)
            if !waitForExit(pid, seconds: Self.exitWaitSeconds) {
                processes.forceKill(pid)
                _ = waitForExit(pid, seconds: 2)
            }
        }
        // Native's own copy may take the lock at once when switching to it, which is fine.
        let deadline = now() + 3
        while !processes.lockIsFree() {
            if !nativeSide, case let .native(pid) = processes.lockHolder(), processes.isAlive(pid) { return }
            guard now() < deadline else {
                throw SwitchError("voice-type.instance.lock is still held (pid \(Self.pid(of: processes.lockHolder())))")
            }
            sleep(0.25)
        }
    }

    private func waitForExit(_ pid: Int32, seconds: Double) -> Bool {
        let deadline = now() + seconds
        while processes.isAlive(pid) {
            guard now() < deadline else { return false }
            sleep(0.1)
        }
        return true
    }

    private static func pid(of holder: LockHolder) -> String {
        switch holder {
        case let .native(pid): return String(pid)
        case let .python(pid): return pid.map(String.init) ?? "unknown"
        case .nobody: return "unknown"
        }
    }

    private static func failure(_ what: String, _ error: Error, undo: [String], keeps: String) -> String {
        let why = error.localizedDescription
        if undo.isEmpty { return "Couldn't \(what): \(why). Put things back, so \(keeps) is still the one in use." }
        return "Couldn't \(what): \(why). Putting things back also failed (\(undo.joined(separator: "; "))). Run `voice-type-native status` and switch again."
    }

    private func waitUntilIdle(name: String, activity: () -> PeerActivity) throws {
        let deadline = now() + Self.busyWaitSeconds
        var announced = false
        while case let .busy(what) = activity() {
            if !announced {
                say("Waiting for \(name) to finish (\(what))...")
                announced = true
            }
            guard now() < deadline else { throw SwitchError("\(name) is still busy (\(what)); try again in a moment.") }
            sleep(0.25)
        }
    }
}

/// The native app's own "Switch to Python", in the order that never leaves the keyboard dead
/// or two apps listening: check Python can start before anything changes, turn the tap off,
/// let go of the lock, start Python. If that fails, take the lock back and only then turn the
/// tap on again.
public final class NativeHandover {
    public enum Outcome: Equatable {
        case handedOver
        /// Native stays in charge, tap back on.
        case stayed(String)
        /// It failed, but Python got the lock anyway, so it's in charge; native should quit.
        case pythonTookOver(String)
    }

    private let switcher: Switcher
    private let lock: LockOwning
    private let stopTap: () -> Void
    private let startTap: () -> Void

    public init(switcher: Switcher, lock: LockOwning, stopTap: @escaping () -> Void, startTap: @escaping () -> Void) {
        self.switcher = switcher
        self.lock = lock
        self.stopTap = stopTap
        self.startTap = startTap
    }

    public func toPython() -> Outcome {
        do { try switcher.checkCanSwitchToPython() } catch { return .stayed(error.localizedDescription) }
        stopTap()
        do {
            try switcher.switchToPythonFromNativeApp(releaseLock: lock.releaseLock)
            return .handedOver
        } catch {
            if lock.holdsLock || lock.takeLock() {
                startTap()
                return .stayed(error.localizedDescription)
            }
            switcher.leavePythonInCharge()
            return .pythonTookOver(error.localizedDescription)
        }
    }
}
