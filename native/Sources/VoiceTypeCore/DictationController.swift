import Foundation

/// What the controller is doing, for the menu and the status file.
public struct ControllerSnapshot: Equatable, Sendable {
    public var phase: DictationController.Phase
    public var enabled: Bool
    public var message: String
    public var modelState: InferenceWorker.ModelState
    public var microphone: String
    public var preferredMicrophone: String
    public var finalizeInFlight: Bool
    public var lastDictation: FinaliseOutcome?

    /// Whether the keyboard tap should swallow F12 and Right Control. Not while paused or
    /// without a model: dictation won't happen, so the keys keep their usual jobs. While
    /// starting it does, as Python did, so a press shows why nothing is recording; starting
    /// always ends, in ready or a restart.
    public var swallowsHotkeys: Bool { enabled && phase != .needsModel }
}

/// Push-to-talk as one state machine on one serial queue: starting, idle, recording,
/// finalising and stopping. It replaces the 100 Hz loop in voice-type.py's hotkey_worker
/// with events (key up and down from the tap, first audio, timers, finished work), and has no
/// hardware in it, so it's tested with fakes.
///
/// Every method has to be called on `ports.queue`. Slow work goes elsewhere: readiness on its
/// own lane, the final pass and the paste on the finalise lane, whisper on its own thread.
public final class DictationController: @unchecked Sendable {
    public enum Phase: String, Sendable {
        /// Checking the microphone, loading or warming the model, or reconnecting audio.
        case starting
        case idle
        case recording
        /// Saving, transcribing and pasting; key-down is ignored until it's done.
        case finalising
        /// About to quit, restart or hand over to Python.
        case stopping
        /// No model file yet.
        case needsModel = "needs_model"
    }

    /// Closures and objects the controller only touches on its own queue (or that are
    /// thread-safe themselves), which Swift can't see, hence the unchecked Sendable.
    public struct Ports: @unchecked Sendable {
        public var recorder: Recorder
        public var transcriber: Transcribing
        public var readiness: MicrophoneReadiness
        public var pill: PillPresenting
        public var finaliser: Finaliser
        public var frontmostApp: () -> TargetApp?
        public var archive: RecordingArchive
        public var loadSettings: () -> SettingsFile
        public var log: (String) -> Void
        /// Logs a backtrace and exits 75, so launchd starts a fresh process.
        public var restartProcess: (String) -> Void
        public var publish: (ControllerSnapshot) -> Void
        public var now: () -> Double
        public var wallClock: () -> Date
        /// The controller's own serial queue, and its timers.
        public var queue: Executor & Scheduler
        public var finaliseLane: Executor
        public var readinessLane: Executor
        public var makeWatchdog: (String, Double, @escaping @Sendable () -> Void) -> OperationWatchdog

        public init(recorder: Recorder, transcriber: Transcribing, readiness: MicrophoneReadiness, pill: PillPresenting,
                    finaliser: Finaliser, frontmostApp: @escaping () -> TargetApp?, archive: RecordingArchive,
                    loadSettings: @escaping () -> SettingsFile, log: @escaping (String) -> Void,
                    restartProcess: @escaping (String) -> Void, publish: @escaping (ControllerSnapshot) -> Void,
                    now: @escaping () -> Double, wallClock: @escaping () -> Date, queue: Executor & Scheduler,
                    finaliseLane: Executor, readinessLane: Executor,
                    makeWatchdog: @escaping (String, Double, @escaping @Sendable () -> Void) -> OperationWatchdog) {
            self.recorder = recorder
            self.transcriber = transcriber
            self.readiness = readiness
            self.pill = pill
            self.finaliser = finaliser
            self.frontmostApp = frontmostApp
            self.archive = archive
            self.loadSettings = loadSettings
            self.log = log
            self.restartProcess = restartProcess
            self.publish = publish
            self.now = now
            self.wallClock = wallClock
            self.queue = queue
            self.finaliseLane = finaliseLane
            self.readinessLane = readinessLane
            self.makeWatchdog = makeWatchdog
        }
    }

    /// One key hold that started the microphone.
    private struct ActiveRecording {
        var generation: Int
        var downSince: Double
        var target: TargetApp?
        var captureReadyDelay: Double
        var firstAudioDelay: Double?
        var settings: SettingsFile
    }

    public static let previewInterval = 0.5
    public static let previewMinimumSeconds = 0.8
    /// A wall-clock jump this big between ticks means the Mac slept, even if the wake
    /// notification never came (WAKE_RESUME_GAP_SECONDS in runtime_policy.py).
    public static let wakeGapSeconds = 30.0
    public static let tickSeconds = 2.0
    /// The microphone check reports at least every ~10 s (each probe step is bounded at 2 s),
    /// so this long without a word means its thread is stuck inside Core Audio.
    public static let readinessStallSeconds = 30.0

    private let ports: Ports
    public private(set) var phase: Phase = .starting
    public private(set) var enabled = true
    private var message = "Starting..."
    private var settings: SettingsFile
    private var settingsDate: Date?

    private var keyDown = false
    private var forcedStop = false
    private var noticeRevealed = false
    private var lastStartFailed = false
    private var generation = 0
    private var recording: ActiveRecording?
    private var capTimer: Cancellable?
    private var previewTimer: Cancellable?
    private var lastPreview = ""
    private var previewPasses = 0
    private var previewSeconds = 0.0

    private var modelReady = false
    private var micReady = false
    private var warmUpPending = false
    private var preparation = 0
    private var cancelReadiness: AbortFlag?
    private var lastReadinessProgress = 0.0
    private var loadWatchdog: OperationWatchdog?
    private var finalWatchdog: OperationWatchdog?
    private var lastDictation: FinaliseOutcome?

    private var pendingWake = false
    private var pendingDeviceCheck = false
    private var pendingMicrophoneChange = false
    private var pendingIdleAction: (label: String, work: () -> Void)?
    private var lastWall: Date
    private var lastCleanup = -Double.infinity

    public init(ports: Ports) {
        self.ports = ports
        self.settings = ports.loadSettings()
        self.settingsDate = settings.modificationDate
        self.lastWall = ports.wallClock()
        ports.recorder.onFirstAudio = { [weak self] in
            guard let self else { return }
            self.ports.queue.run { self.firstAudio() }
        }
    }

    public var snapshot: ControllerSnapshot {
        ControllerSnapshot(
            phase: phase, enabled: enabled, message: message, modelState: ports.transcriber.modelState,
            microphone: ports.recorder.actualDeviceName, preferredMicrophone: settings.microphoneName,
            finalizeInFlight: phase == .finalising, lastDictation: lastDictation
        )
    }

    // MARK: Starting up

    /// Loads the model and checks the microphone. Dictation starts once both are ready.
    public func start() {
        ports.log("Settings: microphone_name='\(settings.microphoneName)'  audio_recording_enabled=\(settings.audioRecordingEnabled ? "True" : "False")  draw_on_screen_enabled=\(settings.drawOnScreenEnabled ? "True" : "False") (drawing comes in phase 2)")
        cleanUpRecordings()
        let watchdog = ports.makeWatchdog("model-load", Deadlines.modelLoad) { [ports] in
            ports.restartProcess("Final model load exceeded \(Int(Deadlines.modelLoad))s; restarting with a fresh native backend")
        }
        loadWatchdog = watchdog
        watchdog.start()
        ports.transcriber.load { [weak self] result in
            guard let self else { return }
            self.ports.queue.run { self.modelLoaded(result) }
        }
        beginPreparation(reason: "startup", warmUp: false)
        scheduleTick()
    }

    private func modelLoaded(_ result: Result<Void, Error>) {
        loadWatchdog?.complete()
        switch result {
        case .success:
            ports.log("Final model ready.")
            modelReady = true
            checkPreparationDone()
        case let .failure(error as ModelFileMissing):
            ports.log("Speech model missing: \(error.path). Run native/scripts/build-app.sh to install it.")
            phase = .needsModel
            message = "Speech model missing"
            publish()
        case let .failure(error):
            ports.log("Final model failed to load: \(error.localizedDescription)")
            ports.restartProcess("Final model failed to load; restarting Voice Type")
        }
    }

    /// Rebuilds the microphone from scratch and runs the readiness check again, optionally
    /// with a silent warm-up pass. Used at startup, after a wake, after a flatline capture
    /// and when the microphone changes. Never while a dictation is running.
    ///
    /// At startup the check waits as long as it takes, as Python's did. Any other time Core
    /// Audio is suspect (Python restarted at every wake for this), so a microphone that's
    /// there but gives nothing for 45 s, or a Core Audio call that hangs, restarts the process.
    private func beginPreparation(reason: String, warmUp: Bool) {
        preparation += 1
        let id = preparation
        cancelReadiness?.set()
        let cancel = AbortFlag()
        cancelReadiness = cancel
        phase = .starting
        micReady = false
        lastReadinessProgress = ports.now()
        warmUpPending = warmUp && modelReady
        settings = ports.loadSettings()
        settingsDate = settings.modificationDate
        let preferred = settings.microphoneName
        message = MicrophoneReadiness.initialMessage(preferred: preferred)
        if noticeRevealed { ports.pill.showProcessing(message) }
        if reason != "startup" { ports.log("Preparing the microphone again (\(reason)).") }
        // Closing everything means the next stream is opened from a fresh device lookup.
        ports.recorder.close()
        publish()

        if warmUpPending {
            let watchdog = ports.makeWatchdog("wake-warm-up", Deadlines.wakeWarmUp) { [ports] in
                ports.restartProcess("The warm-up pass after wake took over \(Int(Deadlines.wakeWarmUp))s; restarting with a fresh Metal backend")
            }
            watchdog.start()
            let transcriber = ports.transcriber
            ports.finaliseLane.run { [weak self] in
                let started = self?.ports.now() ?? 0
                let ok = (try? transcriber.run { engine, _ in
                    _ = try engine.transcribe([Float](repeating: 0, count: sampleRate / 2), options: TranscribeOptions())
                }) != nil
                watchdog.complete()
                guard let self else { return }
                let took = self.ports.now() - started
                self.ports.queue.run { self.warmUpFinished(id, ok: ok, seconds: took) }
            }
        }

        let readiness = ports.readiness
        let giveUpAfter = reason == "startup" ? nil : ReadinessTiming.deadMicrophoneSeconds
        ports.readinessLane.run { [weak self] in
            let result = readiness.run(preferred: preferred, giveUpAfter: giveUpAfter, report: { text in
                guard let self else { return }
                self.ports.queue.run { self.readinessReport(id, text) }
            }, cancelled: { cancel.isSet })
            guard let self else { return }
            self.ports.queue.run { self.readinessFinished(id, result, reason: reason) }
        }
    }

    private func readinessReport(_ id: Int, _ text: String) {
        guard id == preparation, phase == .starting else { return }
        lastReadinessProgress = ports.now()
        message = text
        if noticeRevealed { ports.pill.showProcessing(text) }
        publish()
    }

    private func readinessFinished(_ id: Int, _ result: ReadinessResult, reason: String) {
        guard id == preparation, phase == .starting else { return }
        switch result {
        case let .ready(outcome):
            ports.recorder.select(outcome.selection)
            micReady = true
            checkPreparationDone()
        case .cancelled:
            break
        case let .coreAudioHung(what):
            ports.restartProcess("\(what) (after \(reason)); restarting with a fresh Core Audio")
        case let .gaveUp(failure):
            ports.restartProcess("The microphone gave no audio for \(Int(ReadinessTiming.deadMicrophoneSeconds))s after \(reason) (\(failure)); restarting with a fresh Core Audio")
        }
    }

    private func warmUpFinished(_ id: Int, ok: Bool, seconds: Double) {
        guard id == preparation else { return }
        if !ok {
            ports.restartProcess("The warm-up pass after wake failed; restarting with a fresh Metal backend")
            return
        }
        ports.log(String(format: "Warm-up pass done in %.2fs.", seconds))
        warmUpPending = false
        checkPreparationDone()
    }

    private func checkPreparationDone() {
        guard phase == .starting else { return }
        guard micReady else { return }
        guard modelReady else {
            // A live microphone isn't enough: on 10 August 2026 the mic and event tap were
            // fine while the model's warm-up had been wedged for hours. Ready means usable.
            message = "Loading the speech model..."
            if noticeRevealed { ports.pill.showProcessing(message) }
            publish()
            return
        }
        guard !warmUpPending else { return }
        if ports.recorder.restartRequired {
            // Closing the old stream hung inside Core Audio, so this process can't open another.
            ports.restartProcess("Core Audio hung while reconnecting the microphone; restarting with a fresh process")
            return
        }
        ports.recorder.prepare()
        if ports.recorder.restartRequired {
            ports.restartProcess("Core Audio hung opening the microphone stream; restarting with a fresh process")
            return
        }
        phase = .idle
        message = ""
        if noticeRevealed {
            noticeRevealed = false
            ports.pill.hide()
        }
        ports.log("Ready. Hold F12 or Right Ctrl to record.")
        publish()
        runPendingIdleWork()
    }

    // MARK: The hotkey

    /// From the event tap, via the queue: F12 or Right Control changed.
    public func hotkeyChanged(down: Bool) {
        keyDown = down
        if down {
            switch phase {
            case .starting, .needsModel:
                // Status stays off screen until someone tries to dictate: every wake used to
                // pop it up, which got in the way. A key press that does nothing needs
                // explaining, though, so it shows from the first press until ready.
                if !noticeRevealed {
                    noticeRevealed = true
                    ports.pill.showProcessing(message)
                }
            case .idle:
                if enabled { startRecording() }
            case .finalising:
                ports.log("Recording ignored while the previous dictation is finalizing.")
            case .recording, .stopping:
                break
            }
            return
        }
        // The cap already stopped this hold; the release just clears the latch.
        if forcedStop {
            forcedStop = false
            return
        }
        if phase == .recording {
            finishRecording()
        } else if lastStartFailed {
            lastStartFailed = false
            ports.log("--- Key UP ignored: recording never started ---")
        }
    }

    private func startRecording() {
        reloadSettingsIfChanged()
        ports.log("--- Key DOWN ---")
        let downSince = ports.now()
        // The app in front now gets the paste, even if something else comes forward later.
        let target = ports.frontmostApp()
        // Clear any completion feedback; REC appears with the first audio.
        ports.pill.hide()
        generation += 1
        let result = ports.recorder.start()
        let ready = ports.now() - downSince
        guard case .started = result else {
            if case let .failed(why) = result {
                ports.log("Microphone stream could not open: \(why). Voice Type will reconnect the microphone.")
            }
            lastStartFailed = true
            ports.pill.hide()
            if ports.recorder.restartRequired {
                ports.restartProcess("microphone stream could not open; relaunching the Core Audio backend")
            } else {
                beginPreparation(reason: "microphone stream could not open", warmUp: false)
            }
            return
        }
        lastStartFailed = false
        phase = .recording
        recording = ActiveRecording(generation: generation, downSince: downSince, target: target, captureReadyDelay: ready,
                                    firstAudioDelay: nil, settings: settings)
        lastPreview = ""
        previewPasses = 0
        previewSeconds = 0
        let gen = generation
        capTimer = ports.queue.schedule(after: Deadlines.maxRecording) { [weak self] in self?.capReached(gen) }
        schedulePreview(gen)
        publish()
    }

    private func firstAudio() {
        guard phase == .recording, var active = recording, active.firstAudioDelay == nil else { return }
        active.firstAudioDelay = ports.now() - active.downSince
        recording = active
        ports.pill.showRecording("")
    }

    private func capReached(_ gen: Int) {
        guard phase == .recording, gen == generation else { return }
        ports.log("--- Recording exceeded \(Int(Deadlines.maxRecording))s safety cap; force-stopping ---")
        // Ignore the stuck-looking key until it's really let go.
        if keyDown { forcedStop = true }
        finishRecording()
    }

    // MARK: Live preview

    private func schedulePreview(_ gen: Int) {
        previewTimer = ports.queue.schedule(after: Self.previewInterval) { [weak self] in self?.previewTick(gen) }
    }

    private func previewTick(_ gen: Int) {
        guard phase == .recording, gen == generation, let active = recording else { return }
        let samples = ports.recorder.snapshot()
        if AudioGate.isMissingAudio(sampleCount: samples.count, keyHoldSeconds: ports.now() - active.downSince) {
            // The stream started but nothing has come: say so now rather than at key-up,
            // which reconnects the microphone.
            ports.pill.showRecording(AudioGate.nativeFlatlineRecordingMessage)
            schedulePreview(gen)
            return
        }
        guard Double(samples.count) >= Self.previewMinimumSeconds * Double(sampleRate) else {
            schedulePreview(gen)
            return
        }
        let levels = AudioLevels(samples: samples)
        if AudioGate.isFlatlineAudioCapture(durationSec: levels.durationSec, rms: levels.rms, peak: levels.peak) {
            // Whisper turns a stream of zeros into "Thank you." Keep that out of the preview;
            // key-up sees the same zeros and reconnects the microphone.
            lastPreview = ""
            ports.pill.showRecording(AudioGate.nativeFlatlineRecordingMessage)
            schedulePreview(gen)
            return
        }
        let started = ports.now()
        ports.transcriber.preview(samples, prompt: active.settings.dictation.vocabularyPrompt) { [weak self] transcript in
            guard let self else { return }
            self.ports.queue.run { self.previewFinished(gen, transcript, levels: levels, started: started) }
        }
    }

    private func previewFinished(_ gen: Int, _ transcript: Transcript?, levels: AudioLevels, started: Double) {
        guard phase == .recording, gen == generation else { return }
        if let transcript {
            let text = PreviewFormat.previewText(transcript)
            previewPasses += 1
            previewSeconds = ports.now() - started
            // Nothing said yet, or said very quietly: the same check as the final pass, so
            // "Thank you." over silence never shows, while quiet real words do.
            if AudioGate.isLongNearSilentClip(durationSec: levels.durationSec, peak: levels.peak) && AudioGate.isSilenceHallucination(text) {
                lastPreview = ""
            } else {
                lastPreview = text
                ports.pill.showRecording(PreviewFormat.wrap(text))
            }
        }
        schedulePreview(gen)
    }

    // MARK: Key-up

    private func finishRecording() {
        guard let active = recording else { return }
        capTimer?.cancel()
        previewTimer?.cancel()
        ports.log("--- Key UP ---")
        // One line for the dictation's live preview, rather than one every half second, which
        // filled the log now that native no longer restarts (and rotates it) at every wake.
        if previewPasses > 0 {
            ports.log(String(format: "Live preview: %d pass%@, the last took %.2fs.", previewPasses, previewPasses == 1 ? "" : "es", previewSeconds))
        }
        // Before the microphone stops: drop waiting previews and abort a running one, so the
        // final pass waits for one encoder step at most.
        ports.transcriber.beginFinal()
        let keyUpAt = ports.now()
        let keyHold = keyUpAt - active.downSince
        let samples = ports.recorder.stop()
        let stopTook = ports.now() - keyUpAt
        recording = nil
        phase = .finalising

        let s = active.settings
        var metadata: [(key: String, value: JSONValue)] = [
            ("mode", .string(Finaliser.mode)),
            ("final_model", .string("large-v3-turbo")),
            ("stream_model", .string("large-v3-turbo")),
            ("microphone", .string(ports.recorder.actualDeviceName)),
            ("preferred_microphone", s.json["microphone_name"] ?? .string(SettingsFile.defaultMicrophoneName)),
            ("key_hold_seconds", .double(keyHold)),
            ("capture_ready_delay_seconds", .double(active.captureReadyDelay)),
            ("first_audio_delay_seconds", active.firstAudioDelay.map { .double($0) } ?? .null),
            ("formatter_enabled", .bool(false)),
            ("vocabulary", s.vocabularyForRecording),
        ]
        metadata.append(("app", .string("native")))
        metadata.append(("engine", .string("whisper.cpp b5454 ggml-large-v3-turbo-q8_0")))

        let duration = Double(samples.count) / Double(sampleRate)
        let timeout = Deadlines.finalisation(durationSec: duration)
        let watchdog = ports.makeWatchdog("finalization", timeout) { [ports] in
            ports.restartProcess(String(format: "Final transcription exceeded %.1fs; restarting with a fresh native backend (automatic retry is disabled to avoid duplicate injection)", timeout))
        }
        finalWatchdog = watchdog
        watchdog.start()
        let job = FinaliseJob(samples: samples, metadata: metadata, preview: PreviewFormat.wrap(lastPreview), target: active.target,
                              settings: s, keyUpAt: keyUpAt, stopAudioSeconds: stopTook, keyHoldSeconds: keyHold)
        let finaliser = ports.finaliser
        ports.finaliseLane.run { [weak self] in
            let outcome = finaliser.run(job)
            guard let self else { return }
            self.ports.queue.run { self.finalisationFinished(outcome) }
        }
        // Normally nothing to do: the stream is kept for the next key-down. Reopens it if a
        // device change made it stale meanwhile.
        ports.recorder.prepare()
        publish()
    }

    private func finalisationFinished(_ outcome: FinaliseOutcome) {
        finalWatchdog?.complete()
        finalWatchdog = nil
        ports.transcriber.endFinal()
        lastDictation = outcome
        phase = .idle
        if ports.recorder.restartRequired {
            ports.restartProcess("Core Audio capture needs recovery; relaunching before another microphone stream is opened")
            return
        }
        if outcome.flatline {
            // The pill already says the microphone is being reconnected, so the readiness
            // messages that follow stay on screen until it's back.
            noticeRevealed = true
            beginPreparation(reason: "the microphone delivered digital silence", warmUp: false)
            return
        }
        publish()
        runPendingIdleWork()
    }

    // MARK: System events

    /// macOS woke. Python restarted its whole process here and reloaded the model; native
    /// rebuilds the audio, checks the microphone again and does one silent warm-up pass,
    /// and never in the middle of a dictation.
    public func systemWoke() {
        switch phase {
        case .recording, .finalising:
            ports.log("macOS woke during a dictation; reconnecting audio once it's done.")
            pendingWake = true
        case .idle, .starting:
            ports.log("macOS wake notification received; rebuilding audio before Core Audio or Metal is reused.")
            beginPreparation(reason: "wake", warmUp: true)
        case .stopping, .needsModel:
            break
        }
    }

    /// Core Audio's device list or default input changed (the app debounces bursts).
    public func audioDevicesChanged() {
        switch phase {
        case .recording:
            ports.recorder.invalidate()
            pendingDeviceCheck = true
        case .finalising:
            pendingDeviceCheck = true
        case .idle:
            let names = ports.recorder.catalog.inputDevices().map(\.name)
            func present(_ name: String) -> Bool { names.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            let preferred = settings.microphoneName
            switch ports.recorder.currentSelection {
            case let .named(name) where !present(name):
                ports.log("Input '\(name)' went away; checking the microphone again.")
                beginPreparation(reason: "the microphone went away", warmUp: false)
            case .systemDefault where !preferred.isEmpty && present(preferred):
                ports.log("Preferred microphone '\(preferred)' is back; checking it.")
                beginPreparation(reason: "the preferred microphone came back", warmUp: false)
            default:
                ports.log("Audio devices changed; the next recording will resolve the microphone again.")
                ports.recorder.invalidate()
                ports.recorder.prepare()
                if ports.recorder.restartRequired {
                    ports.restartProcess("Core Audio hung reopening the microphone stream; restarting with a fresh process")
                }
            }
        case .starting, .stopping, .needsModel:
            break
        }
    }

    /// The microphone choice in settings.json changed (from the menu).
    public func microphoneSettingChanged() {
        switch phase {
        case .idle, .starting:
            beginPreparation(reason: "the microphone setting changed", warmUp: false)
        case .recording, .finalising:
            pendingMicrophoneChange = true
        case .stopping, .needsModel:
            break
        }
    }

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        ports.log("Voice Type \(on ? "enabled" : "disabled") via the menu.")
        publish()
    }

    /// Runs `work` once nothing is being dictated, with the phase set to stopping so no new
    /// dictation starts. For a restart, or handing over to Python.
    public func whenIdle(_ label: String, _ work: @escaping () -> Void) {
        switch phase {
        case .idle, .starting, .needsModel:
            cancelReadiness?.set()
            phase = .stopping
            publish()
            work()
        case .recording, .finalising:
            ports.log("\(label) once this dictation is done.")
            pendingIdleAction = (label, work)
        case .stopping:
            break
        }
    }

    /// Back to normal after a hand-over that didn't happen.
    public func resumeAfterCancelledStop() {
        guard phase == .stopping else { return }
        beginPreparation(reason: "the switch didn't happen", warmUp: false)
    }

    private func runPendingIdleWork() {
        guard phase == .idle else { return }
        if let action = pendingIdleAction {
            pendingIdleAction = nil
            phase = .stopping
            publish()
            action.work()
        } else if pendingWake {
            pendingWake = false
            pendingDeviceCheck = false
            pendingMicrophoneChange = false
            beginPreparation(reason: "wake", warmUp: true)
        } else if pendingMicrophoneChange {
            pendingMicrophoneChange = false
            pendingDeviceCheck = false
            beginPreparation(reason: "the microphone setting changed", warmUp: false)
        } else if pendingDeviceCheck {
            pendingDeviceCheck = false
            audioDevicesChanged()
        }
    }

    // MARK: Housekeeping

    private func scheduleTick() {
        ports.queue.schedule(after: Self.tickSeconds) { [weak self] in self?.tick() }
    }

    /// Every couple of seconds: spot a sleep the wake notification missed, restart if the
    /// microphone check is stuck, and clean up old recordings once an hour.
    func tick() {
        let wall = ports.wallClock()
        let gap = wall.timeIntervalSince(lastWall)
        lastWall = wall
        if gap > Self.wakeGapSeconds {
            ports.log(String(format: "System resume detected after a %.1fs gap.", gap))
            systemWoke()
        }
        if phase == .starting && !micReady && ports.now() - lastReadinessProgress > Self.readinessStallSeconds {
            ports.restartProcess("The microphone check has been stuck for over \(Int(Self.readinessStallSeconds))s (Core Audio hung); restarting with a fresh process")
        }
        if ports.now() - lastCleanup >= 3600 { cleanUpRecordings() }
        scheduleTick()
    }

    private func cleanUpRecordings() {
        lastCleanup = ports.now()
        let ports = self.ports
        DispatchQueue.global(qos: .utility).async {
            let removed = ports.archive.cleanup()
            if removed > 0 { ports.log("Deleted \(removed) expired recording archive file(s).") }
        }
    }

    /// Python read settings.json once at startup. Native looks at its modification time at
    /// each key-down, so a hand edit to the word list or corrections applies straight away.
    private func reloadSettingsIfChanged() {
        guard settings.modificationDate != settingsDate else { return }
        let file = ports.loadSettings()
        let micChanged = file.microphoneName != settings.microphoneName
        settings = file
        settingsDate = file.modificationDate
        ports.log("settings.json changed; using the new word list and corrections.")
        if micChanged { pendingMicrophoneChange = true }
    }

    private func publish() { ports.publish(snapshot) }
}
