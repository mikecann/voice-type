import Foundation

/// Somewhere to run work later. The app uses GCD queues; the tests use ManualExecutor so they
/// decide exactly when each step happens.
public protocol Executor: AnyObject, Sendable {
    func run(_ work: @escaping @Sendable () -> Void)
}

public final class QueueExecutor: Executor, Scheduler, @unchecked Sendable {
    public let queue: DispatchQueue

    public init(_ queue: DispatchQueue) { self.queue = queue }

    public func run(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    @discardableResult
    public func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemCancellable(item)
    }
}

final class WorkItemCancellable: Cancellable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

/// Runs something that can hang inside the OS (Core Audio's stop after a wake, mostly) on a
/// throwaway thread and stops waiting after `timeout`. A hang then leaks one thread instead of
/// wedging whoever called it. Returns false on a timeout, and the caller has to assume the
/// thing it called is now unsafe to touch again.
public enum BoundedRunner {
    public static func run(timeout: Double, name: String, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            work()
            done.signal()
        }
        thread.name = name
        thread.start()
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// How long native operations get before Voice Type gives up on its own process.
public enum Deadlines {
    /// Loading and warming whisper.cpp on Metal (MODEL_LOAD_TIMEOUT in voice-type.py).
    public static let modelLoad = 180.0
    /// The silent warm-up pass after a wake.
    public static let wakeWarmUp = 10.0
    /// Starting or stopping the microphone (STREAM_CLOSE_TIMEOUT).
    public static let audioStartStop = 2.0
    /// The 120 s cap on one dictation, in case the key looks stuck down.
    public static let maxRecording = 120.0

    /// Long recordings get longer, but there's never an unbounded wait. From operation_watchdog.py.
    public static func finalisation(durationSec: Double) -> Double { max(30, durationSec * 2) }
}

/// Calls `onTimeout` once if `complete()` doesn't come first. Metal and Core Audio calls can't
/// be cancelled, so the handler logs what it can and exits for launchd to start a fresh
/// process. Ported from operation_watchdog.py.
public final class OperationWatchdog: @unchecked Sendable {
    public let name: String
    public let timeout: Double
    private let onTimeout: @Sendable () -> Void
    private let lock = NSLock()
    private var finished = false
    private var started = false
    private let queue: DispatchQueue

    public init(name: String, timeout: Double, queue: DispatchQueue = .global(qos: .utility), onTimeout: @escaping @Sendable () -> Void) {
        self.name = name
        self.timeout = timeout
        self.queue = queue
        self.onTimeout = onTimeout
    }

    public func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            let fire = lock.withLock { () -> Bool in
                defer { finished = true }
                return !finished
            }
            if fire { onTimeout() }
        }
    }

    public func complete() {
        lock.withLock { finished = true }
    }
}

/// A flag one thread sets and another polls, for whisper.cpp's abort callback.
public final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}
