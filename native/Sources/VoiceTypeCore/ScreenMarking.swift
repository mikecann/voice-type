import Foundation

/// Drawing while dictating, as the controller sees it: start at key-down, hand the marks
/// over at key-up, or throw them away if the microphone never started. Called on the
/// controller's queue only.
public protocol MarkSessions: AnyObject, Sendable {
    /// Key-down, once the dictation's gates have passed and before the microphone opens:
    /// starts drawing if the key is still down. `wordTimings` gets the word timing context
    /// loading once a mark has been captured.
    func begin(wordTimings: Bool)
    /// The microphone is running. `audioOrigin` is when the first sample was captured, on the
    /// controller's clock; a mark finished before it goes before the first word.
    func microphoneStarted(audioOrigin: Double)
    /// The microphone couldn't start, so there's no dictation: stops drawing and throws away
    /// whatever was drawn, its ink and any screenshot already taken.
    func abandon()
    /// Key-up: stops drawing and returns what was drawn, or nil if nothing was.
    func finish() -> DictationMarks?
    /// Deletes screenshots past their week. Returns how many.
    func cleanUp() -> Int
}

/// The real one: the drawing session (mouse tap and ink tracker) and the capture worker.
public final class ScreenMarking: MarkSessions, @unchecked Sendable {
    private let drawing: DrawingSession
    private let capturer: MarkCapturer
    private let store: ScreenshotStore
    private let log: (String) -> Void
    /// Starts the live ink on screen (it hops to the main thread itself).
    private let onBegin: () -> Void
    /// A mark was captured: get the word timing engine ready before key-up. Not for a mark
    /// that couldn't be captured (no Screen Recording, say), which will never get a marker,
    /// so the 1 GB context isn't loaded for nothing.
    private let onMark: @Sendable () -> Void
    private var session: CaptureSession?
    private var audioOrigin = 0.0

    public init(drawing: DrawingSession, capturer: MarkCapturer, store: ScreenshotStore, log: @escaping (String) -> Void,
                onBegin: @escaping () -> Void = {}, onMark: @escaping @Sendable () -> Void = {}) {
        self.drawing = drawing
        self.capturer = capturer
        self.store = store
        self.log = log
        self.onBegin = onBegin
        self.onMark = onMark
        // Called on the event tap's thread: a queue hop, nothing more.
        drawing.tracker.setOnStroke { [capturer] stroke in capturer.submit(stroke) }
    }

    public func begin(wordTimings: Bool) {
        guard drawing.isAvailable else { return }
        session = capturer.begin(onCapture: wordTimings ? onMark : nil)
        guard drawing.begin() else {
            // The key went up before drawing could start.
            capturer.finish([])
            session = nil
            return
        }
        onBegin()
    }

    public func microphoneStarted(audioOrigin: Double) {
        guard session != nil else { return }
        self.audioOrigin = audioOrigin
    }

    public func abandon() {
        guard session != nil else { return }
        session = nil
        // The capture session goes first, so a mark the end below finishes is never captured.
        capturer.abandon()
        // Lets the mouse go (bar a mouse-up the app is still owed, which the tap keeps
        // swallowing) and takes the strokes, which takes their ink off the screen.
        let strokes = drawing.end()
        if !strokes.isEmpty { log("Dropped \(strokes.count) screen mark(s): the microphone didn't start, so there's no dictation to paste them into.") }
    }

    public func finish() -> DictationMarks? {
        guard session != nil else { return nil }
        session = nil
        // The tap thread already stopped swallowing the mouse at key-up; this collects what
        // was drawn, and queues any mark it hadn't handed over yet.
        let strokes = drawing.end()
        let capture = capturer.finish(strokes)
        guard !strokes.isEmpty else { return nil }
        log("\(strokes.count) screen mark(s) drawn.")
        return DictationMarks(strokes: strokes, session: capture, audioOrigin: audioOrigin, log: log)
    }

    public func cleanUp() -> Int { store.cleanup() }
}
