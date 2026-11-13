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
public final class InferenceWorker: @unchecked Sendable {
    public enum ModelState: String, Sendable { case notStarted = "not-started", loading, ready, failed }

    private struct Preview {
        var samples: [Float]
        var completion: (Transcript?) -> Void
    }

    private let makeEngine: () throws -> DictationEngine
    private let condition = NSCondition()
    private var engine: DictationEngine?
    private var jobs: [() -> Void] = []
    private var preview: Preview?
    private var finalRequested = false
    private var runningPreview: AbortFlag?
    private var state: ModelState = .notStarted
    private var promptCache: (prompt: String?, tokens: [Int32])?
    private var thread: Thread?

    public init(makeEngine: @escaping () throws -> DictationEngine) {
        self.makeEngine = makeEngine
    }

    public var modelState: ModelState { condition.withLock { state } }

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
                result = Result { try body(engine, { self.tokens(for: $0, engine: engine) }) }
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
