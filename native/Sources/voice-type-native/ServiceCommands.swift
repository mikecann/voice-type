import Foundation
import VoiceTypeCore
import VoiceTypeMac

/// The commands for running Voice Type rather than testing it: status and restart. They
/// work without the app, so they can say what's wrong, or start it, when it isn't running.
struct ServiceCommands {
    let options: Options
    let launch = ProcessLaunchControl()

    /// How long `restart` waits for a dictation to finish: they're capped at 120 s and
    /// finalisation gets a little more.
    static let busyWaitSeconds = 150.0

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
        let label = LaunchAgents.nativeLabel
        let loaded = launch.isLoaded(label) ? (launch.isRunning(label) ? "running" : "loaded") : "not loaded"
        say("LaunchAgent (\(label)): \(loaded)\(launch.isDisabled(label) ? ", disabled" : "")")
        guard let native else {
            say("Voice Type Native: no status file at \(NativeStatus.defaultURL.path)")
            exit(1)
        }
        say("Voice Type Native: \(alive ? "running" : "not running") (pid \(native.pid), last update \(native.updatedAt))")
        say("  state: \(native.state)\(native.message.isEmpty ? "" : " (\(native.message.replacingOccurrences(of: "\n", with: " ")))")")
        say("  model: \(native.modelStatus), hotkey: \(native.hotkeyListener), holds the lock: \(native.holdsLock)")
        say("  microphone: \(native.microphone.isEmpty ? "none yet" : native.microphone) (preferred: \(native.preferredMicrophone.isEmpty ? "System Default" : native.preferredMicrophone))")
        say("  permissions: \(native.permissions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        say("  clipboard access: \(native.pasteboardAccess)")
        if let last = native.lastDictation {
            say("  last dictation: \(last.at), \(last.status), \(String(format: "%.1f", last.seconds)) s, \(last.words) words, landed: \(last.landed.map { $0 ? "yes" : "no" } ?? "n/a")")
        }
        exit(alive && native.isReady ? 0 : 1)
    }

    /// Restarts the app once nothing is being dictated, then waits until the new one is
    /// ready. The app does the waiting itself (on SIGUSR1), so a key press can't slip in
    /// between a check here and the restart. If launchd isn't running it (Quit from its menu,
    /// or the agent was never loaded), it's started instead.
    func restart() {
        let label = LaunchAgents.nativeLabel
        let old = NativeStatus.read()
        let running = old.map { $0.state != "stopped" && isNative($0.pid) } ?? false
        var done = "Restarted"
        do {
            // A disabled agent wouldn't start at login.
            if launch.isDisabled(label) { try launch.enable(label) }
            if !launch.isLoaded(label) {
                say("Starting Voice Type Native...")
                try LaunchAgents.start(launch)
                done = "Started"
            } else if options.force || !running {
                say("Restarting Voice Type Native now...")
                try launch.kickstart(label, restart: true)
            } else if let old {
                if old.isBusy { say("Waiting for the current dictation to finish...") }
                kill(old.pid, SIGUSR1)
                let deadline = Date().addingTimeInterval(Self.busyWaitSeconds)
                while isNative(old.pid) && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
                if isNative(old.pid) { fail("Voice Type Native (pid \(old.pid)) didn't restart. Try `voice-type-native restart --force`.", code: 1) }
                // launchd starts it again at once unless it had only just started.
                if !launch.isRunning(label) { try? launch.kickstart(label, restart: false) }
            }
        } catch {
            fail(error.localizedDescription, code: 1)
        }
        say("Waiting for Voice Type Native to be ready...")
        if waitForReady(newerThan: old?.pid, timeout: 90) {
            say("\(done) and ready (pid \(NativeStatus.read()?.pid ?? 0)).")
        } else {
            say("It's running but isn't ready yet; `voice-type-native status` shows why.")
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
    /// Opens one of the running app's windows. Nothing happens if it isn't running.
    func show() {
        let what = options.positional.first ?? "settings"
        guard ["settings", "words", "permissions", "history"].contains(what) else {
            fail("show takes settings, words, permissions or history, not \(what)")
        }
        NativeApp.requestShow(what)
        // The notification is delivered asynchronously; give it a moment before exiting.
        Thread.sleep(forTimeInterval: 0.2)
    }

    func launchAgentPlist() {
        guard let executable = options.positional.first else { fail("launch-agent-plist needs the app's executable path") }
        print(LaunchAgents.nativePlistContents(executable: executable), terminator: "")
    }
}
