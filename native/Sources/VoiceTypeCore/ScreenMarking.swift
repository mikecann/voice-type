import Foundation

/// Drawing while dictating, as the controller sees it: start when a recording starts, hand
/// the marks over at key-up. Called on the controller's queue only.
public protocol MarkSessions: AnyObject, Sendable {
    /// The microphone has just started for a recording. Starts drawing if the key is still
    /// down. `audioOrigin` is when the first sample was captured, on the controller's clock.
    /// `wordTimings` gets the word timing context loading once a mark has been captured.
    func begin(audioOrigin: Double, wordTimings: Bool)
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

    public func begin(audioOrigin: Double, wordTimings: Bool) {
        guard drawing.isAvailable else { return }
        session = capturer.begin(onCapture: wordTimings ? onMark : nil)
        guard drawing.begin() else {
            // The key went up before drawing could start.
            capturer.finish([])
            session = nil
            return
        }
        self.audioOrigin = audioOrigin
        onBegin()
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
