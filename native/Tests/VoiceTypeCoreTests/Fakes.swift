import Foundation
@testable import VoiceTypeCore

/// Runs queued work and timers only when a test says so, on a virtual clock.
final class ManualExecutor: Executor, Scheduler, @unchecked Sendable {
    private(set) var now = 0.0
    private var queued: [() -> Void] = []
    private var timers: [(at: Double, seq: Int, token: Token, work: () -> Void)] = []
    private var seq = 0

    final class Token: Cancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    func run(_ work: @escaping @Sendable () -> Void) { queued.append(work) }

    @discardableResult
    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        seq += 1
        let token = Token()
        timers.append((now + seconds, seq, token, work))
        return token
    }

    /// Runs queued work (and whatever it queues) until nothing is left. Timers don't fire.
    func drain() {
        while !queued.isEmpty {
            let work = queued.removeFirst()
            work()
        }
    }

    /// Moves the clock forward, firing timers in order and draining after each.
    func advance(_ seconds: Double) {
        let end = now + seconds
        drain()
        while let next = timers.filter({ !$0.token.cancelled && $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            timers.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.work()
            drain()
        }
        now = end
        timers.removeAll { $0.token.cancelled }
    }

    /// Sleeping on the virtual clock, for code that blocks (readiness, the paste).
    func sleep(_ seconds: Double) { now += seconds }
}

final class FakeCatalog: AudioDeviceCatalog, @unchecked Sendable {
    var devices: [InputDevice]
    var defaultDevice: InputDevice?

    init(_ devices: [InputDevice], default defaultDevice: InputDevice? = nil) {
        self.devices = devices
        self.defaultDevice = defaultDevice ?? devices.first
    }

    func inputDevices() -> [InputDevice] { devices }
    func defaultInputDevice() -> InputDevice? { defaultDevice }
}

final class FakeStream: AudioInputStream, @unchecked Sendable {
    let name: String
    let log: (String) -> Void
    var failStart = false
    var onAudio: ([Float]) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    init(name: String, log: @escaping (String) -> Void) {
        self.name = name
        self.log = log
    }

    func start() throws {
        if failStart { throw MicrophoneUnavailable("start failed") }
        log("start \(name)")
    }

    func stop() throws { log("stop \(name)") }
    func close() { log("close \(name)") }
    func abandon() { log("abandon \(name)") }
}

final class FakeStreamFactory: AudioStreamFactory, @unchecked Sendable {
    private(set) var events: [String] = []
    private(set) var streams: [FakeStream] = []
    var failOpen = false
    var failNextStart = false
    /// Runs while a stream opens, before failOpen throws: the user clicking while the
    /// microphone is still opening.
    var whileOpening: () -> Void = {}

    func open(_ device: InputDevice, onAudio: @escaping @Sendable ([Float]) -> Void, onError: @escaping @Sendable (String) -> Void) throws -> AudioInputStream {
        whileOpening()
        if failOpen { throw MicrophoneUnavailable("open failed") }
        let stream = FakeStream(name: "s\(streams.count + 1):\(device.name)", log: { [unowned self] in self.events.append($0) })
        stream.onAudio = onAudio
        stream.onError = onError
        if failNextStart {
            stream.failStart = true
            failNextStart = false
        }
        streams.append(stream)
        events.append("open \(stream.name)")
        return stream
    }

    /// Delivers audio from the most recently opened stream.
    func deliver(_ samples: [Float]) { streams.last?.onAudio(samples) }
}

final class FakeProbe: MicrophoneProbing, @unchecked Sendable {
    let catalog: AudioDeviceCatalog
    /// How many probes deliver digital silence before the microphone comes good.
    var silentProbes = 0
    /// Core Audio hangs starting the probe's stream.
    var hangs = false
    private(set) var probed: [MicrophoneSelection] = []

    init(catalog: AudioDeviceCatalog) { self.catalog = catalog }

    func probe(_ selection: MicrophoneSelection, seconds: Double) throws -> ProbeResult {
        probed.append(selection)
        let device = try DeviceResolver.resolve(selection, in: catalog)
        if hangs { throw CoreAudioHang("starting the probe") }
        if silentProbes > 0 {
            silentProbes -= 1
            return ProbeResult(ready: false, device: device, reason: "digital silence")
        }
        return ProbeResult(ready: true, device: device)
    }
}

final class ScriptedEngine: DictationEngine, @unchecked Sendable {
    var segments: [String]
    /// Word timings for the first segment, given only when they're asked for.
    var timedWords: [TimedText] = []
    private(set) var finalOptions: [TranscribeOptions] = []
    var fail = false
    /// Runs inside every final transcription, to look at the world mid-pass.
    var duringTranscribe: () -> Void = {}
    private(set) var finals: [[Float]] = []
    private(set) var aborts: [AbortFlag?] = []

    init(_ segments: [String]) { self.segments = segments }

    func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
        try transcribe(samples, options: options, abort: nil)
    }

    func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
        aborts.append(abort)
        if abort == nil {
            finals.append(samples)
            finalOptions.append(options)
            duringTranscribe()
        }
        if fail { throw MicrophoneUnavailable("whisper failed") }
        return Transcript(segments: segments.enumerated().map { i, text in
            TranscriptSegment(text: text, startSec: 0, endSec: 1, noSpeechProb: 0.01, tokenProbs: [0.9, 0.8],
                              words: options.wordTimings && i == 0 ? timedWords : [])
        })
    }

    func promptTokens(for prompt: String?) -> [Int32] { prompt == nil ? [] : [1, 2, 3] }
}

/// A synchronous stand-in for InferenceWorker. Previews wait until the test releases them.
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    let engine: ScriptedEngine
    var modelState: InferenceWorker.ModelState = .notStarted
    var loadResult: Result<Void, Error>? = .success(())
    private var pendingLoad: ((Result<Void, Error>) -> Void)?
    private(set) var previewRequests: [(samples: Int, completion: (Transcript?) -> Void)] = []
    private(set) var finalBegun = 0
    private(set) var finalEnded = 0
    var warmUpFails = false

    init(_ engine: ScriptedEngine) { self.engine = engine }

    func load(completion: @escaping (Result<Void, Error>) -> Void) {
        modelState = .loading
        if let loadResult { finishLoad(loadResult, completion) } else { pendingLoad = completion }
    }

    func completeLoad(_ result: Result<Void, Error> = .success(())) {
        if let pendingLoad { finishLoad(result, pendingLoad) }
        pendingLoad = nil
    }

    private func finishLoad(_ result: Result<Void, Error>, _ completion: (Result<Void, Error>) -> Void) {
        if case .success = result { modelState = .ready } else { modelState = .failed }
        completion(result)
    }

    func run<T>(_ body: @escaping (DictationEngine, (String?) -> [Int32]) throws -> T) throws -> T {
        if warmUpFails { throw MicrophoneUnavailable("warm-up failed") }
        return try body(engine, { self.engine.promptTokens(for: $0) })
    }

    func preview(_ samples: [Float], prompt: String?, completion: @escaping (Transcript?) -> Void) {
        previewRequests.append((samples.count, completion))
    }

    func releasePreview(_ text: String?) {
        guard !previewRequests.isEmpty else { return }
        let request = previewRequests.removeFirst()
        request.completion(text.map { Transcript(segments: [TranscriptSegment(text: $0, startSec: 0, endSec: 1, noSpeechProb: 0, tokenProbs: [])]) })
    }

    func beginFinal() { finalBegun += 1 }
    func endFinal() { finalEnded += 1 }

    /// What the timing pass returns; nil means there's no timing engine.
    var timingTranscript: Transcript?
    /// The timing pass never finishes, like one stuck in Metal: its wait runs out.
    var timingHangs = false
    private(set) var timingPrepared = 0
    private(set) var timingPasses = 0
    private(set) var timingTimeouts: [Double] = []
    private(set) var timingPromptTokens: [[Int32]] = []
    private(set) var timingDrops: [String] = []
    private(set) var lastTimingPass: WordTimingPass?
    func prepareWordTimings() { timingPrepared += 1 }
    func startWordTimings(_ samples: [Float], promptTokens: [Int32], timeout: Double) -> WordTimingPass {
        timingPasses += 1
        timingTimeouts.append(timeout)
        timingPromptTokens.append(promptTokens)
        // A real (short) deadline for a hung pass, so the finaliser really waits it out.
        let pass = timingHangs ? WordTimingPass(timeout: 0.05) : .finished(timingTranscript)
        lastTimingPass = pass
        return pass
    }
    func dropWordTimings(reason: String) { timingDrops.append(reason) }
    var wordTimingsLoaded = true
}

final class FakePill: PillPresenting, @unchecked Sendable {
    private(set) var calls: [String] = []
    var last: String? { calls.last }

    func showRecording(_ preview: String) { calls.append("rec:\(preview)") }
    func showProcessing(_ preview: String) { calls.append("processing:\(preview)") }
    func showDone(words: Int) { calls.append("done:\(words)") }
    func showDone(words: Int, shots: Int) { calls.append("done:\(words)+\(shots)") }
    func showPasteFailed(_ miss: FocusMiss?) { calls.append(miss.map { "paste_failed:\($0.role)" } ?? "paste_failed") }
    func showScreenRecordingHint() { calls.append("hint") }
    func showClipboardNotKept() { calls.append("clipboard_not_kept") }
    func showRecovered(count: Int, seconds: Double) { calls.append("recovered:\(count)") }
    func showSecondsLeft(_ seconds: Int) { calls.append("left:\(seconds)") }
    func hide() { calls.append("hide") }
}

final class FakePaster: Pasting, @unchecked Sendable {
    var landed = true
    var throwError = false
    var clipboard = PasteboardSnapshot.Readability.complete
    /// What a paste that didn't land says had focus.
    var focusMiss: FocusMiss?
    var duringPaste: () -> Void = {}
    private(set) var pasted: [(text: String, target: TargetApp?)] = []
    private(set) var sequences: [(text: String, images: [Data])] = []

    func paste(_ text: String, into target: TargetApp?) throws -> PasteOutcome {
        duringPaste()
        if throwError { throw PasteError() }
        pasted.append((text, target))
        return PasteOutcome(landed: landed, readLatency: landed ? 0.01 : nil, focusRole: "AXTextArea", refocused: false, clipboard: clipboard,
                            focusMiss: landed ? nil : focusMiss)
    }

    func pasteSequence(text: String, images: [Data], into target: TargetApp?) throws -> Paster.SequenceOutcome {
        duringPaste()
        if throwError { throw PasteError() }
        sequences.append((text, images))
        let total = (PythonText.strip(text).isEmpty ? 0 : 1) + images.count
        return Paster.SequenceOutcome(pasted: landed ? total : 0, total: total, landed: landed, focusRole: "AXTextArea", refocused: false, clipboard: clipboard,
                                      focusMiss: landed ? nil : focusMiss)
    }
}

/// A whole controller wired to fakes, the way the app wires the real things.
final class ControllerHarness: @unchecked Sendable {
    let executor = ManualExecutor()
    let catalog: FakeCatalog
    let factory = FakeStreamFactory()
    let probe: FakeProbe
    let engine = ScriptedEngine(["Port it to kuda."])
    let transcriber: FakeTranscriber
    let pill = FakePill()
    let paster = FakePaster()
    let directory: URL
    let archive: RecordingArchive
    let history: TranscriptionHistory
    var settingsJSON: JSONValue
    private(set) var logs: [String] = []
    private(set) var restarts: [String] = []
    private(set) var snapshots: [ControllerSnapshot] = []
    private(set) var watchdogs: [(name: String, timeout: Double, fire: () -> Void)] = []
    var frontmost: TargetApp? = TargetApp(pid: 42, name: "T3 Code")
    var coreAudioHangs = false
    var wall = Date(timeIntervalSince1970: 1_792_548_000)
    var recorder: Recorder!
    var controller: DictationController!

    let marks: MarkSessions?
    private(set) var spool: RecordingSpool?
    private(set) var recovery: DictationRecovery?
    private(set) var recovered: [RecoveredDictation] = []

    init(devices: [InputDevice] = [InputDevice(id: 1, name: "MacBook Pro Microphone"), InputDevice(id: 2, name: "Yeti Stereo Microphone")],
         settings: JSONValue = .object([("audio_recording_enabled", .bool(true)), ("vocabulary", .strings(["Convex"]))]),
         readinessLane: ManualExecutor? = nil, finaliseLane: ManualExecutor? = nil, marks: MarkSessions? = nil,
         spool: Bool = false, recovery: Bool = false,
         beforeStart: (URL) throws -> Void = { _ in }) throws {
        self.marks = marks
        catalog = FakeCatalog(devices, default: devices.first)
        probe = FakeProbe(catalog: catalog)
        transcriber = FakeTranscriber(engine)
        directory = try temporaryDirectory("controller")
        archive = RecordingArchive(directory: directory.appendingPathComponent("recordings"))
        history = TranscriptionHistory(url: directory.appendingPathComponent("transcription-history.jsonl"))
        settingsJSON = settings
        let log: @Sendable (String) -> Void = { [unowned self] in self.logs.append($0) }
        // What an earlier run left in the data folder, before this one starts.
        try beforeStart(directory)
        if spool { self.spool = RecordingSpool(directory: directory.appendingPathComponent("recordings"), log: log) }
        if recovery { self.recovery = DictationRecovery(archive: archive, history: history, transcriber: transcriber, log: log) }
        recorder = Recorder(catalog: catalog, factory: factory, log: log, bounded: { [unowned self] _, work in
            // A hung Core Audio call: the work never finishes in time.
            if self.coreAudioHangs { return false }
            work()
            return true
        })
        let executor = self.executor
        let readiness = MicrophoneReadiness(probe: probe, now: { executor.now }, sleep: { executor.sleep($0) }, log: log)
        let finaliser = Finaliser(transcriber: transcriber, pill: pill, paster: paster, archive: archive, history: history,
                                  log: log, now: { executor.now })
        let ports = DictationController.Ports(
            recorder: recorder, transcriber: transcriber, readiness: readiness, pill: pill, finaliser: finaliser,
            frontmostApp: { [unowned self] in self.frontmost }, archive: archive,
            loadSettings: { [unowned self] in SettingsFile(url: self.directory.appendingPathComponent("settings.json"), json: self.settingsJSON) },
            log: log, restartProcess: { [unowned self] in self.restarts.append($0) },
            publish: { [unowned self] in self.snapshots.append($0) },
            now: { executor.now }, wallClock: { [unowned self] in self.wall },
            queue: executor, finaliseLane: finaliseLane ?? executor, readinessLane: readinessLane ?? executor,
            makeWatchdog: { [unowned self] name, timeout, fire in
                self.watchdogs.append((name, timeout, fire))
                // Never fires by itself; tests fire it through `watchdogs`.
                return OperationWatchdog(name: name, timeout: 86_400 * 365, onTimeout: {})
            },
            marks: marks, spool: self.spool, recovery: self.recovery,
            recovered: { [unowned self] in self.recovered.append(contentsOf: $0) }
        )
        controller = DictationController(ports: ports)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var phase: DictationController.Phase { controller.phase }

    func startAndBecomeReady() {
        controller.start()
        executor.drain()
    }

    func press() {
        controller.hotkeyChanged(down: true)
        executor.drain()
    }

    func release() {
        controller.hotkeyChanged(down: false)
        executor.drain()
    }

    /// Speech-like audio: loud enough for every gate.
    static func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { $0 % 2 == 0 ? 0.1 : -0.1 }
    }

    func dictate(_ samples: [Float]) {
        press()
        factory.deliver(samples)
        executor.drain()
        release()
    }

    func recordingEntries() -> [JSONValue] {
        let dir = directory.appendingPathComponent("recordings")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { try? OrderedJSONParser.parse(Data(contentsOf: dir.appendingPathComponent($0))) }
    }
}
