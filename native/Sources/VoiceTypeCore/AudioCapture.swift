import Foundation

// The microphone side of dictation, with the hardware behind two small protocols so the
// logic can be tested: AudioDeviceCatalog lists inputs, AudioStreamFactory opens one. The
// app's Core Audio versions are in VoiceTypeMac.

public struct InputDevice: Equatable, Sendable {
    /// Core Audio's AudioDeviceID, or a test's stand-in.
    public var id: UInt32
    public var name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol AudioDeviceCatalog: AnyObject, Sendable {
    /// Every device with at least one input channel, in Core Audio's order.
    func inputDevices() -> [InputDevice]
    func defaultInputDevice() -> InputDevice?
}

/// An opened (initialised) input stream. start() turns the microphone on, which is when the
/// orange dot appears; stop() turns it off but keeps the stream for next time.
public protocol AudioInputStream: AnyObject, Sendable {
    func start() throws
    func stop() throws
    func close()
    /// One of this stream's calls hung inside Core Audio. Its thread may still hold the HAL's
    /// lock, so the stream must never be touched again: not stopped, closed or freed (freeing
    /// would close it). Called from another thread while the hung call is still running, so
    /// it mustn't call into Core Audio itself.
    func abandon()
}

/// A Core Audio call that didn't return within its deadline. The process can't safely open
/// another stream after one, so it restarts.
public struct CoreAudioHang: LocalizedError, Equatable {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? { "\(what) hung inside Core Audio for over \(Int(Deadlines.audioStartStop))s" }
}

public protocol AudioStreamFactory: AnyObject, Sendable {
    /// Opens `device` without starting it. `onAudio` gets 16 kHz mono samples while it runs,
    /// on the stream's own thread; `onError` reports a device that died or a failed render.
    func open(_ device: InputDevice, onAudio: @escaping @Sendable ([Float]) -> Void, onError: @escaping @Sendable (String) -> Void) throws -> AudioInputStream
}

public struct MicrophoneUnavailable: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum MicrophoneSelection: Equatable, Sendable {
    /// The system default input, looked up again at every key-down.
    case systemDefault
    /// One device by exact (case-insensitive) name.
    case named(String)
}

public enum DeviceResolver {
    /// Resolves the configured input without quietly falling back. A preferred microphone is
    /// matched by its exact name, case-insensitively, and must be the only device with that
    /// name; if it isn't there, the laptop microphone isn't used instead, since that would make
    /// a recording look healthy while capturing the wrong source. From microphone_readiness.py.
    public static func resolve(_ selection: MicrophoneSelection, in catalog: AudioDeviceCatalog) throws -> InputDevice {
        switch selection {
        case .systemDefault:
            guard let device = catalog.defaultInputDevice() else { throw MicrophoneUnavailable("No default input device") }
            return device
        case let .named(name):
            let matches = catalog.inputDevices().filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1 else { throw MicrophoneUnavailable("Configured microphone '\(name)' is not available") }
            return matches[0]
        }
    }
}

/// Decides when the push-to-talk stream is opened, started and closed. Ported from MicStream
/// in mic_stream.py.
///
/// The stream is opened while idle and only started on key-down. macOS shows the orange
/// microphone dot only while input runs, so the opened stream stays invisible, and key-down
/// doesn't spend the ~35 ms an open takes. Speech in that gap used to be lost from the start
/// of short dictations.
public final class MicStream: @unchecked Sendable {
    public struct Opened {
        public let stream: AudioInputStream
        public let deviceName: String
        /// False for the system default or a fallback. Those can change between recordings,
        /// so key-down resolves the device again.
        public let reusable: Bool

        public init(stream: AudioInputStream, deviceName: String, reusable: Bool) {
            self.stream = stream
            self.deviceName = deviceName
            self.reusable = reusable
        }
    }

    private let openStream: () throws -> Opened
    /// Runs a stop or close off-thread; false means it timed out.
    private let runBounded: (@escaping @Sendable () -> Void) -> Bool
    private let lock = NSRecursiveLock()
    private var opened: Opened?
    // The stale and error flags have their own lock: the audio thread sets them while a stop
    // holding `lock` may be waiting for that same thread to drain.
    private let flags = NSLock()
    private var staleFlag = false
    private var errorFlag = false
    private var stale: Bool {
        get { flags.withLock { staleFlag } }
        set { flags.withLock { staleFlag = newValue } }
    }
    private var errored: Bool {
        get { flags.withLock { errorFlag } }
        set { flags.withLock { errorFlag = newValue } }
    }
    public private(set) var deviceName = ""
    public private(set) var isRunning = false

    public init(open: @escaping () throws -> Opened, runBounded: @escaping (@escaping @Sendable () -> Void) -> Bool) {
        self.openStream = open
        self.runBounded = runBounded
    }

    /// Called from the audio thread when the device reports a problem.
    public func noteError() { errored = true }

    /// Open a fresh stream next time, after a microphone or device change.
    public func invalidate() { stale = true }

    /// Opens, but doesn't start, the stream for the next recording.
    public func prepare() throws {
        try lock.withLock {
            if isRunning || isReusable { return }
            if opened != nil && !stale && !errored {
                // Key-down resolves this device again anyway, so opening another now would
                // only be thrown away.
                return
            }
            close_()
            try open_()
        }
    }

    /// Starts capturing. Returns whether a prepared stream was reused.
    @discardableResult
    public func start() throws -> Bool {
        try lock.withLock {
            var reused = isReusable
            if !reused {
                close_()
                try open_()
            }
            do {
                try opened!.stream.start()
            } catch {
                close_()
                guard reused else { throw error }
                // A prepared stream can go bad while idle, for example if its device was
                // unplugged. Retry once with a fresh one.
                reused = false
                try open_()
                do {
                    try opened!.stream.start()
                } catch {
                    close_()
                    throw error
                }
            }
            isRunning = true
            return reused
        }
    }

    /// Stops capturing, keeping the stream. Returns false if the stop hung, in which case the
    /// stream is abandoned and Core Audio has to be treated as unsafe in this process.
    @discardableResult
    public func stop() -> Bool {
        lock.withLock {
            guard let current = opened, isRunning else { return true }
            isRunning = false
            let stream = current.stream
            if !runBounded({ try? stream.stop() }) {
                // Wedged inside Core Audio: leak it, and never touch it again.
                stream.abandon()
                opened = nil
                return false
            }
            return true
        }
    }

    public func close() { lock.withLock { close_() } }

    private var isReusable: Bool { opened.map { $0.reusable && !stale && !errored } ?? false }

    private func open_() throws {
        // Cleared first so an invalidate() that lands while opening still counts.
        stale = false
        errored = false
        let new = try openStream()
        opened = new
        deviceName = new.deviceName
    }

    private func close_() {
        guard let current = opened else { return }
        opened = nil
        isRunning = false
        let stream = current.stream
        if !runBounded({
            try? stream.stop()
            stream.close()
        }) {
            stream.abandon()
        }
    }
}

/// Audio that belongs to one successful key hold. A failed start must never leave an earlier
/// dictation's audio to be finalised, which is what AudioFrameBuffer and RecordingSession in
/// recording_session.py guard against.
public final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false

    public init() {}

    /// Discards old audio before trying to start a new stream.
    public func resetForStartAttempt() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            recording = false
        }
    }

    /// Marked before the stream starts, so the very first block is kept.
    public func markStarted() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(sampleRate * 10)
            recording = true
        }
    }

    /// Returns true for the first block of a recording.
    @discardableResult
    public func append(_ block: [Float]) -> Bool { take(block).first }

    /// Whether the block belongs to a recording (it doesn't between recordings), and whether
    /// it's the recording's first.
    public func take(_ block: [Float]) -> (kept: Bool, first: Bool) {
        lock.withLock {
            guard recording, !block.isEmpty else { return (false, false) }
            let first = samples.isEmpty
            samples.append(contentsOf: block)
            return (true, first)
        }
    }

    public var hasAudio: Bool { lock.withLock { !samples.isEmpty } }

    public func snapshot() -> [Float] { lock.withLock { samples } }

    public var sampleCount: Int { lock.withLock { samples.count } }

    /// RMS of the last 512 samples (32 ms), which drives the REC bars.
    public var recentRMS: Double {
        lock.withLock {
            let tail = samples.suffix(512)
            guard !tail.isEmpty else { return 0 }
            var sum: Float = 0
            for s in tail { sum += s * s }
            return Double((sum / Float(tail.count)).squareRoot())
        }
    }

    /// Ends the recording and hands its audio over exactly once.
    public func stop() -> [Float] {
        lock.withLock {
            let wasRecording = recording
            recording = false
            let taken = wasRecording ? samples : []
            samples = []
            return taken
        }
    }
}

public enum AudioStartResult: Equatable, Sendable {
    case started(reusedPreparedStream: Bool)
    case failed(String)
}

/// Owns the microphone for dictation: which device, the stream, and the audio captured.
/// The Recorder class in voice-type.py, without PortAudio's quirks.
public final class Recorder: @unchecked Sendable {
    public let catalog: AudioDeviceCatalog
    private let factory: AudioStreamFactory
    private let log: @Sendable (String) -> Void
    private let capture = CaptureBuffer()
    private var mic: MicStream!
    private let bounded: (Double, @escaping @Sendable () -> Void) -> Bool
    private let lock = NSLock()
    private var selection: MicrophoneSelection = .systemDefault
    private var actualName = ""
    private var restartNeeded = false
    /// Called on the audio thread with the first block of each recording.
    public var onFirstAudio: (@Sendable () -> Void)?
    /// Called on the audio thread with every block a recording keeps, in order. Set once,
    /// before the first stream opens, like onFirstAudio. The recording spool uses it.
    public var onRecordedAudio: (@Sendable ([Float]) -> Void)?

    public init(catalog: AudioDeviceCatalog, factory: AudioStreamFactory, log: @escaping @Sendable (String) -> Void,
                bounded: @escaping (Double, @escaping @Sendable () -> Void) -> Bool = { BoundedRunner.run(timeout: $0, name: "voice-type-audio-stop", $1) }) {
        self.catalog = catalog
        self.factory = factory
        self.log = log
        self.bounded = bounded
        self.mic = MicStream(open: { [unowned self] in try self.openStream() }, runBounded: { [unowned self] work in
            if bounded(Deadlines.audioStartStop, work) { return true }
            self.lock.withLock { self.restartNeeded = true }
            self.log("Microphone stop/close timed out after \(Deadlines.audioStartStop)s (Core Audio deadlock); Voice Type will restart once this dictation is done.")
            return false
        })
    }

    /// A stop or close hung inside Core Audio. Its thread may still hold a HAL lock, so this
    /// process mustn't open another stream: it restarts as soon as it's idle.
    public var restartRequired: Bool { lock.withLock { restartNeeded } }

    public var actualDeviceName: String { lock.withLock { actualName } }

    public var currentSelection: MicrophoneSelection { lock.withLock { selection } }

    public var level: Double { capture.recentRMS }

    public var hasAudio: Bool { capture.hasAudio }

    public func snapshot() -> [Float] { capture.snapshot() }

    public func select(_ newSelection: MicrophoneSelection) {
        let changed = lock.withLock { () -> Bool in
            defer { selection = newSelection }
            return selection != newSelection
        }
        if changed { mic.invalidate() }
    }

    public func invalidate() { mic.invalidate() }

    /// Opens the stream for the next key-down without turning the microphone on. Not fatal
    /// if it fails: key-down opens one itself. Bounded like start and stop, since it runs on
    /// the controller's queue and opening a unit (AudioUnitInitialize) can hang after a wake
    /// too; a hang sets `restartRequired`.
    public func prepare() {
        guard !restartRequired else { return }
        let failure = StartOutcome()
        let mic = self.mic!
        guard bounded(Deadlines.audioStartStop, { failure.set(Result { try mic.prepare() }.map { false }) }) else {
            lock.withLock { restartNeeded = true }
            log("Opening the microphone stream timed out after \(Deadlines.audioStartStop)s (Core Audio deadlock); Voice Type will restart.")
            return
        }
        if case let .failure(error)? = failure.get() { log("Could not prepare the microphone stream: \(error.localizedDescription)") }
    }

    public func start() -> AudioStartResult {
        capture.resetForStartAttempt()
        guard !restartRequired else { return .failed("Core Audio needs a restart") }
        // Marked before starting, so the very first block is kept.
        capture.markStarted()
        // Bounded like the stop: a start that hangs inside Core Audio after a wake would
        // otherwise hold the controller (and the stream's lock) for good.
        let outcome = StartOutcome()
        let mic = self.mic!
        guard bounded(Deadlines.audioStartStop, { outcome.set(Result { try mic.start() }) }) else {
            lock.withLock { restartNeeded = true }
            log("Microphone start timed out after \(Deadlines.audioStartStop)s (Core Audio deadlock); Voice Type will restart.")
            return .failed("the microphone start timed out")
        }
        switch outcome.get() {
        case let .success(reused)?:
            if !reused { log("Mic stream was not prepared; opened it on key-down.") }
            return .started(reusedPreparedStream: reused)
        case let .failure(error)?:
            capture.resetForStartAttempt()
            return .failed(error.localizedDescription)
        case nil:
            capture.resetForStartAttempt()
            return .failed("the microphone didn't start")
        }
    }

    private final class StartOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Bool, Error>?
        func set(_ result: Result<Bool, Error>) { lock.withLock { value = result } }
        func get() -> Result<Bool, Error>? { lock.withLock { value } }
    }

    /// Stops the microphone and returns everything captured since start().
    public func stop() -> [Float] {
        // The stream delivers its last converted block before stop() returns. Once Core Audio
        // has hung, the microphone (and its lock, which the hung thread may hold) is left alone.
        if !restartRequired { mic.stop() }
        let audio = capture.stop()
        if audio.isEmpty {
            log("Stopped: no audio arrived.")
        } else {
            let levels = AudioLevels(samples: audio)
            log(String(format: "Stopped: %.2fs  rms=%.4f  peak=%.4f", levels.durationSec, levels.rms, levels.peak))
        }
        return audio
    }

    /// Closes the stream so the next prepare opens everything from scratch. Not once Core
    /// Audio has hung: the hung thread may be holding the stream's lock.
    public func close() {
        guard !restartRequired else { return }
        mic.close()
    }

    private func openStream() throws -> MicStream.Opened {
        let current = currentSelection
        let device = try DeviceResolver.resolve(current, in: catalog)
        let source: String
        if case .named = current { source = "selected" } else { source = "system default" }
        log("Mic (\(source)): '\(device.name)'")
        let stream = try factory.open(device, onAudio: { [weak self] block in
            guard let self else { return }
            let taken = self.capture.take(block)
            if taken.kept { self.onRecordedAudio?(block) }
            if taken.first { self.onFirstAudio?() }
        }, onError: { [weak self] message in
            self?.log("Audio problem: \(message)")
            // Open a fresh stream on the next key press.
            self?.mic.noteError()
        })
        lock.withLock { actualName = device.name }
        if case let .named(name) = current {
            return MicStream.Opened(stream: stream, deviceName: device.name, reusable: device.name.caseInsensitiveCompare(name) == .orderedSame)
        }
        return MicStream.Opened(stream: stream, deviceName: device.name, reusable: false)
    }
}
