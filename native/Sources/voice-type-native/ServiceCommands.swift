import Foundation
import VoiceTypeCore
import VoiceTypeMac

/// The commands for running Voice Type rather than testing it: status, switch and restart.
/// They work without the app, so `switch python` gets you back even when native is broken.
struct ServiceCommands {
    let options: Options
    let launch = ProcessLaunchControl()

    private func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    /// The status file's pid really is Voice Type Native: a pid outlives its process and can
    /// belong to anything later, so the executable is checked, as LockHolder.identify does.
    private func isNative(_ pid: Int32) -> Bool { ProcessLookup.isVoiceTypeNative(pid: pid) }

    func status() {
        let native = NativeStatus.read()
        let alive = native.map { $0.state != "stopped" && isNative($0.pid) } ?? false
        func agent(_ label: String) -> String {
            let loaded = launch.isLoaded(label) ? (launch.isRunning(label) ? "running" : "loaded") : "not loaded"
            return "\(loaded)\(launch.isDisabled(label) ? ", disabled" : "")"
        }
        say("Python agent (\(LaunchAgents.pythonLabel)): \(agent(LaunchAgents.pythonLabel))")
        say("Native agent (\(LaunchAgents.nativeLabel)): \(agent(LaunchAgents.nativeLabel))")
        switch PythonControlSocket().activity() {
        case .notRunning: say("Python Voice Type: not answering")
        case .idle: say("Python Voice Type: running, idle")
        case let .busy(what): say("Python Voice Type: running, \(what)")
        }
        guard let native else {
            say("Voice Type Native: no status file at \(NativeStatus.defaultURL.path)")
            exit(1)
        }
        say("Voice Type Native: \(alive ? "running" : "not running") (pid \(native.pid), last update \(native.updatedAt))")
        say("  state: \(native.state)\(native.message.isEmpty ? "" : " (\(native.message.replacingOccurrences(of: "\n", with: " ")))")")
        say("  model: \(native.modelStatus), hotkey: \(native.hotkeyListener), holds Python's lock: \(native.holdsPythonLock)")
        say("  microphone: \(native.microphone.isEmpty ? "none yet" : native.microphone) (preferred: \(native.preferredMicrophone.isEmpty ? "System Default" : native.preferredMicrophone))")
        say("  permissions: \(native.permissions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        say("  clipboard access: \(native.pasteboardAccess)")
        if let last = native.lastDictation {
            say("  last dictation: \(last.at), \(last.status), \(String(format: "%.1f", last.seconds)) s, \(last.words) words, landed: \(last.landed.map { $0 ? "yes" : "no" } ?? "n/a")")
        }
        exit(alive && native.isReady ? 0 : 1)
    }

    func switchTo() {
        guard let target = options.positional.first, ["native", "python"].contains(target) else {
            fail("switch needs native or python\n\n\(usage)")
        }
        let switcher = Switcher(launch: launch, python: PythonControlSocket(), native: NativeStatusProbe(), processes: SystemVoiceTypeProcesses(), say: say)
        do {
            if target == "native" {
                try switcher.switchToNative()
                say("Waiting for Voice Type Native to be ready...")
                if waitForReady(newerThan: nil, timeout: 90) {
                    say("Voice Type Native is ready. Hold F12 or Right Control to dictate.")
                } else {
                    say("Voice Type Native hasn't said it's ready yet. `voice-type-native status` shows why (often a permission).")
                    exit(1)
                }
            } else {
                try switcher.switchToPython()
                say("Python Voice Type is starting. It takes a few seconds to load its model.")
            }
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    /// Restarts the app once nothing is being dictated, then waits until the new one is
    /// ready. The app does the waiting itself (on SIGUSR1), so a key press can't slip in
    /// between a check here and the restart.
    func restart() {
        guard launch.isLoaded(LaunchAgents.nativeLabel) else {
            fail("Voice Type Native's agent isn't loaded. Use `voice-type-native switch native` to start it.", code: 1)
        }
        let old = NativeStatus.read()
        if options.force || old.map({ $0.state == "stopped" || !isNative($0.pid) }) ?? true {
            say("Restarting Voice Type Native now...")
            do { try launch.kickstart(LaunchAgents.nativeLabel, restart: true) } catch { fail(error.localizedDescription, code: 1) }
        } else if let old {
            if old.isBusy { say("Waiting for the current dictation to finish...") }
            kill(old.pid, SIGUSR1)
            let deadline = Date().addingTimeInterval(Switcher.busyWaitSeconds)
            while isNative(old.pid) && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            if isNative(old.pid) { fail("Voice Type Native (pid \(old.pid)) didn't restart. Try `voice-type-native restart --force`.", code: 1) }
            // launchd starts it again at once unless it had only just started.
            if !launch.isRunning(LaunchAgents.nativeLabel) { try? launch.kickstart(LaunchAgents.nativeLabel, restart: false) }
        }
        say("Waiting for Voice Type Native to be ready...")
        if waitForReady(newerThan: old?.pid, timeout: 90) {
            say("Restarted and ready (pid \(NativeStatus.read()?.pid ?? 0)).")
        } else {
            say("It restarted but isn't ready yet; `voice-type-native status` shows why.")
            exit(1)
        }
    }

    private func waitForReady(newerThan oldPID: Int32?, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = NativeStatus.read(), status.pid != oldPID, isNative(status.pid), status.isReady { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Prints the LaunchAgent for an installed app, for the build script.
    func launchAgentPlist() {
        guard let executable = options.positional.first else { fail("launch-agent-plist needs the app's executable path") }
        print(LaunchAgents.nativePlistContents(executable: executable), terminator: "")
    }
}
