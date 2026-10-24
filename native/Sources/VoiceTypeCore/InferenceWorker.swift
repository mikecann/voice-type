import Foundation

/// A speech engine the app can drive: whisper.cpp, or a fake in the tests.
public protocol DictationEngine: SpeechEngine {
    /// Like transcribe(_:options:), but stops early (best effort, between encoder and decoder
    /// steps) once `abort` is set. Only previews pass a flag.
    func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript
    /// The word list prompt's tokens, made the way the benchmark made them.
    func promptTokens(for prompt: String?) -> [Int32]
}

public struct EngineNotReady: LocalizedError {
    public var errorDescription: String? { "the speech model isn't loaded" }
}

/// The one thread that owns the whisper context, as PLAN.md has it. Finals always go before
/// previews, a key-up aborts a preview that's running, and no preview starts between key-up
/// and the end of that dictation's final pass. It replaces inference_scheduler.py, whose
/// reason still holds: Metal work run side by side turns a quick pass into a slow one.
/// Screen marks' word timing context has a second thread of its own (see startWordTimings).
public final class InferenceWorker: @unchecked Sendable {
    public enum ModelState: String, Sendable { case notStarted = "not-started", loading, ready, failed }

    private struct Preview {
        var samples: [Float]
        var completion: (Transcript?) -> Void
    }

    private let makeEngine: () throws -> DictationEngine
    /// A second whisper.cpp context for screen marks' word timings (see startWordTimings).
    private let makeTimingEngine: (() throws -> DictationEngine)?
    private let log: (String) -> Void
    private let condition = NSCondition()
    private var engine: DictationEngine?
    private var jobs: [() -> Void] = []
    private var preview: Preview?
    private var finalRequested = false
    private var runningPreview: AbortFlag?
    private var state: ModelState = .notStarted
    private var promptCache: (prompt: String?, tokens: [Int32])?
    private var thread: Thread?

    /// The word timing thread's queue and state, under timingCondition.
    private let timingCondition = NSCondition()
    private var timingJobs: [() -> Void] = []
    private var timingThread: Thread?
    /// A final pass (or warm-up) is running on the main thread.
    private var mainBusy = false
    /// The timing thread is inside a job.
    private var timingBusy = false
    /// Whether timingEngine is set, readable from any thread.
    private var timingLoaded = false
    /// A timing pass ran out of time while the timing thread was busy, and that job hasn't
    /// finished yet.
    private var timingOverrun = false
    // Only touched on the timing thread.
    private var timingEngine: DictationEngine?
    private var timingLoadFailed = false
    private var timingUses = 0

    /// The timing engine is freed after this long without a mark or a dictation with marks.
    public let timingIdleSeconds: Double
    /// Runs the idle countdown. Nil is GCD on the wall clock; the tests fire it by hand.
    private let idleTimer: (@Sendable (Double, @escaping @Sendable () -> Void) -> Void)?

    public init(makeEngine: @escaping () throws -> DictationEngine, makeTimingEngine: (() throws -> DictationEngine)? = nil,
                timingIdleSeconds: Double = 300, idleTimer: (@Sendable (Double, @escaping @Sendable () -> Void) -> Void)? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.makeEngine = makeEngine
        self.makeTimingEngine = makeTimingEngine
        self.timingIdleSeconds = timingIdleSeconds
        self.idleTimer = idleTimer
        self.log = log
    }

    /// Whether the word timing engine is loaded, for tests and the log.
    public var timingEngineLoaded: Bool {
        guard timingCondition.withLock({ timingThread != nil }) else { return false }
        let done = DispatchSemaphore(value: 0)
        var loaded = false
        enqueueTiming { [self] in
            loaded = timingEngine != nil
            done.signal()
        }
        done.wait()
        return loaded
    }

    public var modelState: ModelState { condition.withLock { state } }

    /// Whether the word timing engine is loaded right now, without waiting for its thread.
    public var wordTimingsLoaded: Bool { timingCondition.withLock { timingLoaded } }

    /// Starts the thread and loads the model on it. `completion` runs on the worker thread.
    public func load(completion: @escaping (Result<Void, Error>) -> Void) {
        condition.withLock {
            if thread == nil {
                let t = Thread { [weak self] in self?.loop() }
                t.name = "voice-type-inference"
                t.qualityOfService = .userInitiated
                // whisper.cpp's Metal setup wants more than the default 512 KB.
                t.stackSize = 8 << 20
                thread = t
                t.start()
            }
            state = .loading
        }
        enqueue { [self] in
            do {
                let loaded = try makeEngine()
                condition.withLock {
                    engine = loaded
                    state = .ready
                }
                completion(.success(()))
            } catch {
                condition.withLock { state = .failed }
                completion(.failure(error))
            }
        }
    }

    /// Runs `body` with the engine on the worker thread, ahead of any preview, and waits for
    /// it. Used for the final pass and the warm-up.
    public func run<T>(_ body: @escaping (DictationEngine, (String?) -> [Int32]) throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(EngineNotReady())
        enqueue { [self] in
            if let engine = condition.withLock({ self.engine }) {
                setMainBusy(true)
                result = Result { try body(engine, { self.tokens(for: $0, engine: engine) }) }
                setMainBusy(false)
            }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    /// Asks for a preview of `samples`. A newer request replaces one that hasn't started.
    /// `completion` gets nil when the preview was dropped or aborted.
    public func preview(_ samples: [Float], prompt: String?, completion: @escaping (Transcript?) -> Void) {
        condition.withLock {
            guard !finalRequested else {
                completion(nil)
                return
            }
            preview?.completion(nil)
            preview = Preview(samples: samples, completion: { completion($0) })
            promptForPreview = prompt
            condition.signal()
        }
    }

    private var promptForPreview: String?

    // MARK: Word timings for screen marks
    //
    // The timing engine has a thread of its own, so loading it (about 1 GB) or a pass that
    // hangs (Metal can, after a wake) never holds up a final pass or a preview on the main
    // one, and the words are always pasted. It doesn't start anything while a final pass is
    // running, so the two don't share the GPU at key-up either.

    /// A captured mark: load the timing engine now, while the key is still held, so it's
    /// ready by key-up, and keep it for another timingIdleSeconds. Does nothing if there
    /// isn't one, or its thread is still stuck in a pass that ran out of time.
    public func prepareWordTimings() {
        guard makeTimingEngine != nil, !timingCondition.withLock({ timingOverrun }) else { return }
        enqueueTiming { [self] in
            // Restarts the idle countdown even when it's loaded already, so it can't be freed
            // between a mark and its key-up.
            if loadTimingEngine() != nil { scheduleTimingUnload() }
        }
    }

    /// Starts a timing-only pass over `samples` and returns at once; the pass's wait() gives
    /// each word's time for placing "[n]" markers, or nil without a timing engine, if it
    /// failed, or once `timeout` is up (the pass is then told to stop). The engine is a second
    /// whisper.cpp context set up for DTW alignment (cross-attention heads, as mlx-whisper's
    /// word_timestamps did for Python). That needs flash attention off, which would change
    /// the benchmarked text, so it's a separate pass after the final one, whose text is
    /// aligned to the final text word by word. `promptTokens` are the final pass's.
    public func startWordTimings(_ samples: [Float], promptTokens: [Int32], timeout: Double) -> WordTimingPass {
        guard makeTimingEngine != nil else { return .finished(nil) }
        if timingCondition.withLock({ timingOverrun }) {
            log("The last word timing pass is still running; placing markers with the final pass's token timestamps.")
            return .finished(nil)
        }
        let pass = WordTimingPass(timeout: timeout) { [weak self] in self?.noteTimingOverrun() }
        enqueueTiming { [self] in
            // Out of time (or not needed) before it got the thread.
            guard !pass.abort.isSet, let timing = loadTimingEngine(), !pass.abort.isSet else {
                pass.finish(nil)
                return
            }
            do {
                pass.finish(try timing.transcribe(samples, options: TranscribeOptions(promptTokens: promptTokens, wordTimings: true), abort: pass.abort))
            } catch {
                if !pass.abort.isSet { log("Word timing pass failed: \(error.localizedDescription)") }
                pass.finish(nil)
            }
            scheduleTimingUnload()
        }
        return pass
    }

    /// After a wake: frees the timing engine, so the next mark makes a fresh one rather than
    /// reusing a Metal context from before the sleep (the main engine gets a warm-up pass
    /// under a watchdog instead).
    public func dropWordTimings(reason: String) {
        guard makeTimingEngine != nil, timingCondition.withLock({ timingThread != nil }) else { return }
        enqueueTiming { [self] in
            guard timingEngine != nil else { return }
            setTimingEngine(nil)
            timingUses += 1
            log("Word timing model unloaded (\(reason)); the next mark loads it again.")
        }
    }

    /// On the timing thread.
    private func loadTimingEngine() -> DictationEngine? {
        if let timingEngine { return timingEngine }
        guard let makeTimingEngine, !timingLoadFailed else { return nil }
        do {
            let loaded = try makeTimingEngine()
            setTimingEngine(loaded)
            scheduleTimingUnload()
            return loaded
        } catch {
            // Once per run: the token timestamps are the fallback from then on.
            timingLoadFailed = true
            log("The word timing model failed to load (\(error.localizedDescription)); markers will use the final pass's token timestamps.")
            return nil
        }
    }

    /// On the timing thread: frees the timing engine once it's gone unused for
    /// timingIdleSeconds. On the wall clock, which keeps counting while the Mac sleeps,
    /// unlike DispatchTime.
    private func scheduleTimingUnload() {
        timingUses += 1
        let use = timingUses
        let fire: @Sendable () -> Void = { [weak self] in
            self?.enqueueTiming { [weak self] in
                guard let self, self.timingUses == use, self.timingEngine != nil else { return }
                self.setTimingEngine(nil)
                self.log("Word timing model unloaded after \(Int(self.timingIdleSeconds / 60)) minutes without marks.")
            }
        }
        if let idleTimer {
            idleTimer(timingIdleSeconds, fire)
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + timingIdleSeconds, execute: fire)
        }
    }

    /// On the timing thread.
    private func setTimingEngine(_ engine: DictationEngine?) {
        timingEngine = engine
        timingCondition.withLock { timingLoaded = engine != nil }
    }

    /// Whether a timing pass ran out of time and its thread is still busy with it.
    var timingPassStuck: Bool { timingCondition.withLock { timingOverrun } }

    /// A pass ran out of time. If the timing thread is still busy (in that pass, or the load
    /// it was waiting for), later passes don't queue behind it until it's done.
    private func noteTimingOverrun() {
        timingCondition.withLock { if timingBusy { timingOverrun = true } }
    }

    private func enqueueTiming(_ job: @escaping () -> Void) {
        timingCondition.withLock {
            if timingThread == nil {
                let t = Thread { [weak self] in self?.timingLoop() }
                t.name = "voice-type-word-timing"
                t.qualityOfService = .userInitiated
                t.stackSize = 8 << 20
                timingThread = t
                t.start()
            }
            timingJobs.append(job)
            timingCondition.broadcast()
        }
    }

    private func setMainBusy(_ busy: Bool) {
        timingCondition.withLock {
            mainBusy = busy
            timingCondition.broadcast()
        }
    }

    private func timingLoop() {
        while true {
            timingCondition.lock()
            // Waits for a final pass to finish before starting anything.
            while timingJobs.isEmpty || mainBusy { timingCondition.wait() }
            let job = timingJobs.removeFirst()
            timingBusy = true
            timingCondition.unlock()
            job()
            timingCondition.withLock {
                timingBusy = false
                timingOverrun = false
                timingCondition.broadcast()
            }
        }
    }

    /// Key-up: drop the waiting preview, abort the running one, and take no more until
    /// `endFinal`, so the final pass only ever waits for one encoder step.
    public func beginFinal() {
        condition.withLock {
            finalRequested = true
            preview?.completion(nil)
            preview = nil
            runningPreview?.set()
        }
    }

    public func endFinal() {
        condition.withLock { finalRequested = false }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.withLock {
            jobs.append(job)
            condition.signal()
        }
    }

    private func tokens(for prompt: String?, engine: DictationEngine) -> [Int32] {
        if let cache = promptCache, cache.prompt == prompt { return cache.tokens }
        let tokens = engine.promptTokens(for: prompt)
        promptCache = (prompt, tokens)
        return tokens
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty && (preview == nil || finalRequested || engine == nil) {
                condition.wait()
            }
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                condition.unlock()
                job()
                continue
            }
            let next = preview!
            preview = nil
            let prompt = promptForPreview
            let flag = AbortFlag()
            runningPreview = flag
            let engine = self.engine!
            condition.unlock()

            let options = TranscribeOptions(promptTokens: tokens(for: prompt, engine: engine))
            let transcript = try? engine.transcribe(next.samples, options: options, abort: flag)
            condition.withLock { runningPreview = nil }
            next.completion(flag.isSet ? nil : transcript)
        }
    }
}

/// A word timing pass that has been started. Screen marks' markers are optional, so waiting
/// for one is always bounded: past its deadline wait() gives up, tells the pass to stop
/// (whisper.cpp checks between steps), and the caller uses the final pass's token timestamps.
public final class WordTimingPass: @unchecked Sendable {
    /// Set to stop the pass early: it ran out of time, or it isn't needed after all.
    public let abort = AbortFlag()
    private let condition = NSCondition()
    private let deadline: Date
    private let onTimeout: () -> Void
    private var done = false
    private var transcript: Transcript?
    private var timedOut_ = false

    public init(timeout: Double, onTimeout: @escaping () -> Void = {}) {
        deadline = Date(timeIntervalSinceNow: timeout)
        self.onTimeout = onTimeout
    }

    /// A pass that's already over: no timing engine, or its thread is busy.
    public static func finished(_ transcript: Transcript?) -> WordTimingPass {
        let pass = WordTimingPass(timeout: 0)
        pass.finish(transcript)
        return pass
    }

    /// From the timing thread. Too late once wait() has given up.
    public func finish(_ transcript: Transcript?) {
        condition.withLock {
            guard !done else { return }
            done = true
            self.transcript = transcript
            condition.broadcast()
        }
    }

    /// Blocks until the pass is done or its deadline passes.
    public func wait() -> Transcript? {
        let (result, expired): (Transcript?, Bool) = condition.withLock {
            while !done {
                if !condition.wait(until: deadline) { break }
            }
            guard !done else { return (transcript, false) }
            done = true
            timedOut_ = true
            return (nil, true)
        }
        if expired {
            abort.set()
            onTimeout()
        }
        return result
    }

    /// Not needed after all (every capture failed): stop it if it's running.
    public func cancel() { abort.set() }

    /// Whether wait() gave up on it.
    public var timedOut: Bool { condition.withLock { timedOut_ } }
}
