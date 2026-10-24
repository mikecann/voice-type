import AppKit
import Synchronization
import VoiceTypeCore
import VoiceTypeWhisper

/// Voice Type Native as a menu bar app: no Dock icon, its own LaunchAgent and instance lock.
///
/// Threads, as PLAN.md lays them out: the keyboard tap on its own run loop, the controller on
/// one serial queue, Core Audio's callback and a drain queue, whisper on its own thread, the
/// final pass and paste on a finalise queue, readiness on another, and AppKit alone on the
/// main thread. Nothing slow runs on the tap thread or the main thread.
public final class NativeApp: NSObject, NSApplicationDelegate {
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = NativeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private let logFile = LogFile()
    private let lock = InstanceLock()
    private let history = RestartHistory()
    private let launchControl = ProcessLaunchControl()
    private let controllerQueue = DispatchQueue(label: "voice-type.controller", qos: .userInteractive)
    private let statusQueue = DispatchQueue(label: "voice-type.status", qos: .utility)
    private let housekeeping = DispatchQueue(label: "voice-type.housekeeping", qos: .utility)
    private let catalog = CoreAudioCatalog()
    private let permissionsWindow = PermissionsWindow()
    private var menu: StatusMenu!
    private var controller: DictationController?
    private var recorder: Recorder?
    private var tap: KeyboardTap?
    /// Drawing while dictating: the ink tracker and the mouse tap's session, shared by the
    /// keyboard tap (which owns the mouse tap), the controller and the live ink.
    private lazy var drawing = DrawingSession(tracker: InkTracker(clock: { ProcessInfo.processInfo.systemUptime }))
    private var ink: InkOverlay?
    private var deviceWatcher: AudioDeviceWatcher?
    private var stallDetector: StallDetector?
    private var timers: [DispatchSourceTimer] = []
    private var signals: [DispatchSourceSignal] = []
    private var status = NativeStatus(pid: getpid(), state: "starting")
    private var waitingLogged = Set<String>()
    private var tapWarningLogged = false
    private let exiting = Atomic<Bool>(false)
    private var dictationStarted = false
    private var backoff: DispatchWorkItem?
    // On statusQueue: a state of the app's own when there's no controller (retrying or
    // needs_attention), and how long it has been ready, to clear the restart history.
    private var appState: (state: String, message: String)?
    private var readySince: Double?
    private var historyCleared = false

    /// launchd only sets XPC_SERVICE_NAME on the process it started, so this tells a managed
    /// run from one opened by hand (Python's restart_supervisor_active).
    private let supervised = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchAgents.nativeLabel
    private let relaunched = ProcessInfo.processInfo.environment["VOICE_TYPE_NATIVE_RELAUNCH"] == "1"
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    private func log(_ message: String) { logFile.log(message) }

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // launchd's own log for this app gets only what the process prints itself (a crash,
        // say), but nothing ever rotated it.
        LogFile.trimInPlace(LaunchAgents.logDirectory.appendingPathComponent("native-launchd.log"))
        log("=== voice-type-native started === pid=\(getpid()) version=\(version) supervised=\(supervised ? "True" : "False") log=\(logFile.url.path)")
        log("Clipboard access for this app: \(GeneralPasteboard.accessBehavior). Permissions: \(Permission.summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        installSignalHandlers()
        menu = StatusMenu(actions: StatusMenu.Actions(
            chooseMicrophone: { [weak self] in self?.chooseMicrophone($0) },
            setEnabled: { [weak self] on in self?.onController { $0.setEnabled(on) } },
            showPermissions: { [weak self] in self?.permissionsWindow.show() },
            openLog: { [weak self] in if let url = self?.logFile.url { NSWorkspace.shared.open(url) } },
            tryAgain: { [weak self] in self?.tryAgain() },
            quit: { [weak self] in self?.quit() }
        ), catalog: catalog)
        publish(nil)
        if Permission.missing.contains(where: \.isRequired) { permissionsWindow.show() }
        tryLock()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (from Spotlight, say) shows the permissions; settings come in phase 3.
        permissionsWindow.show()
        return false
    }

    private func lockSituation() -> LockPolicy.Situation {
        let holder = lock.recordedPID().map { LockHolder.identify(pid: $0) } ?? .nobody
        var alive = false
        if case let .native(pid) = holder { alive = ProcessLookup.isAlive(pid: pid) }
        let installed = FileManager.default.fileExists(atPath: LaunchAgents.nativePlist.path)
        return LockPolicy.Situation(supervised: supervised, relaunched: relaunched, nativeAgentInstalled: installed,
                                    holder: holder, holderAlive: alive, ownPID: getpid())
    }

    /// No dictation, and no keyboard tap, without the instance lock. See LockPolicy for who
    /// may take it.
    private func tryLock() {
        guard !lock.isHeld else { return }
        switch LockPolicy.plan(lockSituation()) {
        case .take:
            if lock.tryAcquire() {
                lockAcquired()
                return
            }
            noteWaiting("voice-type.instance.lock is held by another process (pid \(lock.recordedPID().map(String.init) ?? "unknown")); waiting for it to let go.")
        case let .wait(why):
            noteWaiting(why)
        case let .quit(why):
            log(why)
            logFile.flush()
            exit(0)
        case .startAgentAndQuit:
            startLaunchdCopyAndQuit()
            return
        }
        publish(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tryLock() }
    }

    private func noteWaiting(_ why: String) {
        if waitingLogged.insert(why).inserted { log(why) }
    }

    /// Opened by hand while the LaunchAgent is installed: start launchd's copy (enabling its
    /// agent if it was disabled, or kickstarting it after Quit from its menu) and quit, so the
    /// copy that dictates is always launchd's.
    private func startLaunchdCopyAndQuit() {
        log("Opened by hand; starting Voice Type Native's LaunchAgent instead of dictating from this copy.")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try LaunchAgents.start(launchControl)
                quitNow("Started Voice Type Native's LaunchAgent; quitting this copy.")
            } catch {
                log("Couldn't start Voice Type Native's LaunchAgent: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    Self.alert("Couldn't start Voice Type Native", "\(error.localizedDescription)\n\nRunning native/scripts/build-app.sh again reinstalls it.")
                    self.quitNow("Quitting after the LaunchAgent didn't start.")
                }
            }
        }
    }

    private func lockAcquired() {
        log("Holding voice-type.instance.lock, so no other copy of Voice Type Native can dictate.")
        repeating(every: 2, on: housekeeping) { [weak self] in self?.noteHealth() }
        let recent = history.recent()
        let plan = RestartBackoff.plan(recent, now: Date())
        switch plan {
        case .startNow:
            startDictation()
        case let .wait(seconds):
            let message = RestartBackoff.message(plan, recent: recent)
            log(message)
            setAppState(("retrying", message))
            let item = DispatchWorkItem { [weak self] in self?.startDictation() }
            backoff = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        case .giveUp:
            // Up, holding the lock so a second copy doesn't start dictating, but without the
            // tap, so F12 and Right Control work as normal keys until someone fixes it.
            log(RestartBackoff.message(plan, recent: recent))
            setAppState(("needs_attention", RestartBackoff.message(plan, recent: recent)))
        }
    }

    private func startDictation() {
        guard !dictationStarted, lock.isHeld else { return }
        dictationStarted = true
        backoff?.cancel()
        setAppState(nil)
        // Made before the controller, which tells it whether to swallow the keys.
        tap = makeTap()
        buildController()
        onController { $0.start() }
        startTap()
        observeSystem()
        deviceWatcher = AudioDeviceWatcher { [weak self] in self?.onController { $0.audioDevicesChanged() } }
        // Every hardware call on the controller's queue is bounded, so a ping that waits
        // 30 s means something unbounded hung there, holding the hotkey with it.
        let detector = StallDetector(timeout: 30, now: { ProcessInfo.processInfo.systemUptime },
                                     ping: { [controllerQueue] work in controllerQueue.async(execute: work) },
                                     onStall: { [weak self] seconds in
                                         self?.restartAfterFailure("The controller's queue has been stuck for \(Int(seconds))s; restarting with a fresh process")
                                     })
        stallDetector = detector
        repeating(every: 5, on: housekeeping) { detector.check() }
        publish(nil)
    }

    private func tryAgain() {
        log("Try Again chosen from the menu; forgetting earlier restarts.")
        history.clear()
        DispatchQueue.main.async { self.startDictation() }
    }

    private func setAppState(_ state: (String, String)?) {
        statusQueue.async { [self] in appState = state.map { (state: $0.0, message: $0.1) } }
        publish(nil)
    }

    /// Ready for a minute: earlier failed restarts no longer count towards the backoff.
    private func noteHealth() {
        statusQueue.async { [self] in
            let healthy = lock.isHeld && appState == nil && ["idle", "recording", "finalising"].contains(status.state) && status.modelStatus == "ready"
            guard healthy else {
                readySince = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard let since = readySince else {
                readySince = now
                return
            }
            if now - since >= 60 && !historyCleared {
                historyCleared = true
                if !history.recent().isEmpty {
                    history.clear()
                    logFile.log("Ready for a minute; earlier restarts no longer count towards the backoff.")
                }
            }
        }
    }
    private func buildController() {
        let log: @Sendable (String) -> Void = { [logFile] in logFile.log($0) }
        let uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
        let recorder = Recorder(catalog: catalog, factory: CoreAudioStreamFactory(), log: log)
        self.recorder = recorder
        let worker = InferenceWorker(makeEngine: {
            let path = VoiceTypePaths.defaultModel.path
            guard FileManager.default.fileExists(atPath: path) else { throw ModelFileMissing(path: path) }
            log("Loading final model 'large-v3-turbo' with whisper.cpp on Metal (\(path))...")
            let engine = try WhisperEngine(modelPath: path)
            // Half a second of silence, as MlxWhisperModel.warm() did, so the first
            // dictation doesn't pay for Metal's setup.
            let started = uptime()
            _ = try engine.transcribe([Float](repeating: 0, count: sampleRate / 2), options: TranscribeOptions())
            log(String(format: "Model loaded in %.0f ms, warmed in %.0f ms.", engine.loadMilliseconds, (uptime() - started) * 1000))
            return engine
        }, makeTimingEngine: {
            // The same model in a second context with DTW alignment, for screen marks'
            // markers: about 1 GB more, only from the first captured mark until 5 minutes after
            // the last (or a wake), and never with "marker_timings": "rough".
            let path = VoiceTypePaths.defaultModel.path
            log("Loading the word timing model for screen marks (whisper.cpp DTW)...")
            let engine = try WhisperEngine(modelPath: path, dtw: true)
            let started = uptime()
            _ = try engine.transcribe([Float](repeating: 0, count: sampleRate / 2), options: TranscribeOptions(wordTimings: true))
            log(String(format: "Word timing model loaded in %.0f ms, warmed in %.0f ms.", engine.loadMilliseconds, (uptime() - started) * 1000))
            return engine
        }, log: log)
        let pill = MainThreadPill(level: { recorder.level })
        let paster = Paster(pasteboard: GeneralPasteboard(), environment: MacPasteEnvironment(), now: uptime,
                            sleep: { Thread.sleep(forTimeInterval: $0) }, log: log)
        let archive = RecordingArchive(directory: VoiceTypePaths.recordingsDirectory)
        let history = TranscriptionHistory(url: VoiceTypePaths.dataDirectory.appendingPathComponent("transcription-history.jsonl"))
        let finaliser = Finaliser(transcriber: worker, pill: pill, paster: paster, archive: archive, history: history, log: log, now: uptime)
        let readiness = MicrophoneReadiness(probe: CoreAudioProbe(catalog: catalog), now: uptime, sleep: { Thread.sleep(forTimeInterval: $0) }, log: log)
        let ports = DictationController.Ports(
            recorder: recorder, transcriber: worker, readiness: readiness, pill: pill, finaliser: finaliser,
            frontmostApp: {
                NSWorkspace.shared.frontmostApplication.map { TargetApp(pid: $0.processIdentifier, name: $0.localizedName ?? "unknown") }
            },
            archive: archive, loadSettings: { SettingsFile.load() }, log: log,
            restartProcess: { [weak self] reason in self?.restartAfterFailure(reason) },
            publish: { [weak self] snapshot in self?.publish(snapshot) },
            now: uptime, wallClock: Date.init,
            queue: QueueExecutor(controllerQueue),
            finaliseLane: QueueExecutor(DispatchQueue(label: "voice-type.finalise", qos: .userInitiated)),
            readinessLane: QueueExecutor(DispatchQueue(label: "voice-type.readiness", qos: .userInitiated)),
            makeWatchdog: { name, timeout, fire in OperationWatchdog(name: name, timeout: timeout, onTimeout: fire) },
            marks: makeScreenMarking(log: log, onMark: { worker.prepareWordTimings() })
        )
        controller = DictationController(ports: ports)
    }

    private func onController(_ work: @escaping (DictationController) -> Void) {
        controllerQueue.async { [weak self] in
            guard let controller = self?.controller else { return }
            work(controller)
        }
    }

    /// The tap needs Accessibility and Input Monitoring; without them creating it fails, so
    /// it's tried again every two seconds and starts working as soon as they're granted.
    private func startTap() {
        // Never without the lock, and never without a controller to take the keys (backing
        // off, or given up).
        guard lock.isHeld, dictationStarted, !exiting.load(ordering: .relaxed) else { return }
        if tap == nil { tap = makeTap() }
        guard let tap, tap.status != .running else { return }
        if tap.start() {
            log("Keyboard tap installed: hold F12 or Right Control to dictate\(drawing.isAvailable ? ", and drag or click to draw while holding it" : "").")
            publish(nil)
            return
        }
        if !tapWarningLogged {
            tapWarningLogged = true
            log("Keyboard tap unavailable: grant Accessibility and Input Monitoring in System Settings > Privacy & Security. Retrying every 2 s.")
        }
        publish(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startTap() }
    }

    private func makeTap() -> KeyboardTap {
        KeyboardTap(drawing: drawing, log: { [logFile] in logFile.log($0) }) { [weak self] down in
            self?.onController { $0.hotkeyChanged(down: down) }
        }
    }

    /// The capture worker, the screenshot store and the live ink, for the controller.
    private func makeScreenMarking(log: @escaping @Sendable (String) -> Void, onMark: @escaping @Sendable () -> Void) -> ScreenMarking {
        let store = ScreenshotStore(directory: VoiceTypePaths.dataDirectory.appendingPathComponent("screenshots"))
        let capturer = MarkCapturer(store: store, log: log, capture: { try MacScreen.capture($0) },
                                    allowed: { MacScreen.captureAllowed }, request: { MacScreen.requestCapture() })
        let ink = InkOverlay(tracker: drawing.tracker)
        self.ink = ink
        return ScreenMarking(drawing: drawing, capturer: capturer, store: store, log: log,
                             onBegin: { DispatchQueue.main.async { ink.start() } }, onMark: onMark)
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            // A key-up lost in sleep must not leave push-to-talk on.
            self?.tap?.reset()
            self?.onController { $0.systemWoke() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            // Docking changes the displays and often the audio devices; Python reopened the
            // stream here. Core Audio's own notification usually covers it too.
            self?.onController { $0.audioDevicesChanged() }
        }
    }

    // MARK: Status

    /// Merges the controller's view with the app's (lock, tap, permissions), then writes the
    /// status file and updates the menu. Only the copy holding the lock writes the file, so a
    /// second copy opened by hand doesn't overwrite what the one dictating says.
    private func publish(_ snapshot: ControllerSnapshot?) {
        let holdsLock = lock.isHeld
        let tapStatus = tap?.status.rawValue ?? KeyboardTap.Status.notStarted.rawValue
        if let snapshot { tap?.setSwallowing(snapshot.swallowsHotkeys) }
        statusQueue.async { [self] in
            if let snapshot {
                status.state = snapshot.phase.rawValue
                status.message = snapshot.message
                status.enabled = snapshot.enabled
                status.modelStatus = snapshot.modelState.rawValue
                status.microphone = snapshot.microphone
                status.preferredMicrophone = snapshot.preferredMicrophone
                status.finalizeInFlight = snapshot.finalizeInFlight
                if let last = snapshot.lastDictation {
                    status.lastDictation = NativeStatus.LastDictation(at: Timestamp(Date()).utcISOFormat, status: last.status,
                                                                      seconds: last.durationSec, words: last.words, landed: last.landed)
                }
            }
            status.holdsLock = holdsLock
            status.hotkeyListener = tapStatus
            status.permissions = Permission.summary
            status.pasteboardAccess = GeneralPasteboard.accessBehavior
            status.version = version
            status.updatedAt = Timestamp(Date()).utcISOFormat
            var shown = status
            if let appState {
                shown.state = appState.state
                shown.message = appState.message
            } else if !holdsLock {
                shown.state = "waiting_for_lock"
            } else if shown.state == "idle" && tapStatus != KeyboardTap.Status.running.rawValue {
                shown.state = "waiting_for_permission"
            }
            if holdsLock {
                do { try shown.write() } catch { logFile.log("Status file write failed: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { self.menu?.update(shown) }
        }
    }

    private func writeFinalStatus(_ state: String) {
        guard lock.isHeld else { return }
        statusQueue.sync {
            status.state = state
            status.holdsLock = false
            status.updatedAt = Timestamp(Date()).utcISOFormat
            try? status.write()
        }
    }

    // MARK: Leaving

    /// A watchdog fired or Core Audio can't be trusted: log what every thread was doing and
    /// exit 75 so launchd starts a fresh process. Never waits on the controller, which may be
    /// what's stuck, and never retries the dictation, so nothing is pasted twice. The restart
    /// is recorded, so a fault that comes back every launch backs off and then stops.
    private func restartAfterFailure(_ reason: String) {
        guard !exiting.exchange(true, ordering: .relaxed) else { return }
        log(reason)
        history.record(reason)
        let failures = history.recent().count
        if failures <= RestartBackoff.dumpThreadsUpTo {
            HangReport.capture(reason: reason, log: { [logFile] in logFile.log($0) })
        } else {
            log("Restart \(failures) in \(Int(RestartBackoff.windowSeconds / 60)) min; no thread dump this time.")
        }
        exitForRestart()
    }

    private func exitForRestart() {
        exiting.store(true, ordering: .relaxed)
        log("=== voice-type-native exiting with 75 so launchd restarts it ===")
        if !supervised {
            // Nobody will restart a copy opened by hand, so start the next one now. It waits
            // for this one to let go of the lock. (Only without a LaunchAgent: with one, a
            // hand-opened copy never dictates.)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", "--env", "VOICE_TYPE_NATIVE_RELAUNCH=1", Bundle.main.bundlePath]
            try? open.run()
        }
        writeFinalStatus("stopped")
        logFile.flush()
        exit(75)
    }

    private func quitNow(_ why: String) -> Never {
        exiting.store(true, ordering: .relaxed)
        log(why)
        tap?.stop()
        writeFinalStatus("stopped")
        logFile.flush()
        exit(0)
    }

    private func quit() {
        guard controller != nil else { quitNow("Quit from the menu.") }
        onController { [weak self] in $0.whenIdle("Quitting") { self?.quitNow("Quit from the menu.") } }
    }

    private func installSignalHandlers() {
        // `voice-type-native restart` sends SIGUSR1: restart as soon as nothing is being
        // dictated. launchd's bootout sends SIGTERM: finish a dictation first if one is
        // running, but never take longer than launchd's 20 s grace.
        for number in [SIGUSR1, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                switch number {
                case SIGUSR1:
                    // Asked for, so not a failure: it doesn't count towards the backoff, and
                    // it's the way out of giving up after a fix (the build script sends it).
                    self.log("Restart requested from the command line; restarting once idle.")
                    self.history.clear()
                    guard self.controller != nil else { self.exitForRestart(); return }
                    self.onController { $0.whenIdle("Restarting") { self.exitForRestart() } }
                default:
                    self.log("Signal SIGTERM received; shutting down.")
                    guard self.controller != nil else { self.quitNow("Stopped by launchd.") }
                    self.onController { $0.whenIdle("Stopping") { self.quitNow("Stopped by launchd.") } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.quitNow("Stopped by launchd (timed out waiting for the dictation).") }
                }
            }
            source.resume()
            signals.append(source)
        }
    }

    // MARK: Menu actions

    private func chooseMicrophone(_ name: String) {
        housekeeping.async { [weak self] in
            guard let self else { return }
            var settings = SettingsFile.load()
            guard settings.microphoneName != name else { return }
            self.log("Input device switching to '\(name.isEmpty ? "System Default" : name)'...")
            settings.set("microphone_name", .string(name))
            do { try settings.save() } catch { self.log("Settings save failed: \(error.localizedDescription)") }
            self.onController { $0.microphoneSettingChanged() }
            self.publish(nil)
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func repeating(every seconds: Double, on queue: DispatchQueue, _ work: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(200))
        timer.setEventHandler(handler: work)
        timer.resume()
        timers.append(timer)
    }
}
