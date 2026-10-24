import Foundation

// Turning screen marks into annotated screenshots, ported from mark_capture.py.
//
// Each finished mark is queued from the event tap thread and captured on a worker while the
// key is still held, so the screenshot shows what was pointed at when it was drawn. The
// window under the mark is captured on its own with `screencapture -o -l <id>`; over bare
// desktop a generous region of that display (`-R`) is captured instead.
//
// Marks on the same window share one screenshot. Each new mark on a window redraws all of
// that window's marks onto its own, newer capture and replaces the file, so the work is done
// before key-up and pasting doesn't wait on it.

/// What to capture for a mark: its window, or a desktop region.
public struct CaptureTarget: Equatable, Sendable {
    public var rect: MarkRect
    public var args: [String]
    public var description: String
    /// The window's number, or nil for a desktop region.
    public var window: Int?

    public init(rect: MarkRect, args: [String], description: String, window: Int? = nil) {
        self.rect = rect
        self.args = args
        self.description = description
        self.window = window
    }

    public struct GroupKey: Hashable, Sendable {
        var window: Int
        var rect: MarkRect
    }

    /// Marks with the same key share one screenshot. Only windows group, and only while they
    /// stay put: if a window moved or resized between marks, the earlier marks' ink wouldn't
    /// line up with a newer capture. Desktop regions are centred on each mark, so they never
    /// match.
    public var groupKey: GroupKey? { window.map { GroupKey(window: $0, rect: rect) } }

    public static func choose(for stroke: Stroke, windows: [WindowInfo], displays: [MarkRect], ownPID: Int32) -> CaptureTarget? {
        let anchor = ScreenMarks.anchor(stroke)
        if let window = ScreenMarks.chooseWindow(windows, at: anchor, excluding: [ownPID]) {
            // -o leaves the window's shadow out, so the ink offsets are exact.
            return CaptureTarget(rect: window.bounds, args: ["-o", "-l", String(window.number)],
                                 description: "\(window.ownerName ?? "window") #\(window.number)", window: window.number)
        }
        guard let display = ScreenMarks.display(containing: anchor, in: displays) else { return nil }
        let r = ScreenMarks.desktopRegion(display, around: anchor)
        let (x, y, w, h) = (ScreenMarks.pythonRound(r.x), ScreenMarks.pythonRound(r.y), ScreenMarks.pythonRound(r.width), ScreenMarks.pythonRound(r.height))
        let region = "\(x),\(y),\(w),\(h)"
        return CaptureTarget(rect: MarkRect(Double(x), Double(y), Double(w), Double(h)), args: ["-R", region], description: "desktop \(region)")
    }
}

/// One dictation's screenshots, filled in by the capture worker.
public final class CaptureSession: @unchecked Sendable {
    struct Group {
        var strokes: [Stroke]
        var path: String
    }

    public let ident: Int
    /// Called on the capture worker after each mark is captured (only when the word timing
    /// context is wanted), so it's loaded only once there's a screenshot to mark.
    let onCapture: (@Sendable () -> Void)?
    private let condition = NSCondition()
    private var submitted: Set<Int> = []
    /// Mark number -> the file showing it, or nil if it failed. Marks that share a window all
    /// point at the same file.
    private var paths: [Int: String?] = [:]
    private var permissionMissing_ = false
    private var expected: Set<Int>?
    /// Set once finalisation has taken the paths, so a late recomposite doesn't delete a file
    /// that's about to be pasted.
    private var collected = false
    /// Only the worker touches this.
    var groups: [CaptureTarget.GroupKey: Group] = [:]

    init(ident: Int, onCapture: (@Sendable () -> Void)? = nil) {
        self.ident = ident
        self.onCapture = onCapture
    }

    public var permissionMissing: Bool { condition.withLock { permissionMissing_ } }

    /// At least one mark has its screenshot already.
    var hasScreenshot: Bool { condition.withLock { paths.values.contains { $0 != nil } } }

    /// False once no mark can end up with a screenshot: Screen Recording is missing, or every
    /// mark has been settled without one.
    var mayHaveScreenshots: Bool {
        condition.withLock {
            if permissionMissing_ { return false }
            guard let expected, expected.isSubset(of: paths.keys) else { return true }
            return expected.contains { paths[$0] != .some(nil) }
        }
    }

    /// Blocks until every expected mark is captured (or failed), then returns (number, path)
    /// pairs in mark order.
    public func wait(timeout: Double) -> [(number: Int, path: String)] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while let expected, !expected.isSubset(of: paths.keys) {
            if !condition.wait(until: deadline) { break }
        }
        collected = true
        return paths.compactMap { number, path in path.map { (number, $0) } }.sorted { $0.number < $1.number }
    }

    /// False if this mark was already handed over.
    func claim(_ number: Int) -> Bool { condition.withLock { submitted.insert(number).inserted } }

    /// Closes the session: these are all its marks. Returns the ones never handed over.
    func expect(_ strokes: [Stroke]) -> [Stroke] {
        condition.withLock {
            expected = Set(strokes.map(\.number))
            let pending = strokes.filter { submitted.insert($0.number).inserted }
            condition.broadcast()
            return pending
        }
    }

    func notePermissionMissing() { condition.withLock { permissionMissing_ = true } }

    /// Records a capture for these marks. Returns whether finalisation already took the paths.
    func record(_ path: String, for numbers: [Int]) -> Bool {
        condition.withLock {
            for number in numbers { paths[number] = .some(path) }
            condition.broadcast()
            return collected
        }
    }

    /// A captured mark already has its path; this settles a failed one so wait() stops
    /// expecting it.
    func settle(_ number: Int) {
        condition.withLock {
            if paths[number] == nil { paths[number] = .some(nil) }
            condition.broadcast()
        }
    }
}

/// Queues marks from the tap thread and captures them one at a time on its own worker.
public final class MarkCapturer: @unchecked Sendable {
    public typealias Capture = (Stroke) throws -> (png: Data, target: CaptureTarget)?
    public typealias Composite = (Data, MarkRect, [Stroke]) throws -> Data

    private let store: ScreenshotStoring
    private let log: (String) -> Void
    private let capture: Capture
    private let composite: Composite
    private let allowed: () -> Bool
    private let request: () -> Void
    private let worker: DispatchQueue
    private let lock = NSLock()
    private var session: CaptureSession?
    private var nextIdent = 0
    /// Screen Recording is asked for once per run (the worker's alone).
    private var requested = false

    public init(store: ScreenshotStoring, log: @escaping (String) -> Void, capture: @escaping Capture,
                composite: @escaping Composite = { try MarkCompositor.compositePNG($0, captureRect: $1, strokes: $2) },
                allowed: @escaping () -> Bool = { true }, request: @escaping () -> Void = {},
                worker: DispatchQueue = DispatchQueue(label: "voice-type.mark-capture", qos: .userInitiated)) {
        self.store = store
        self.log = log
        self.capture = capture
        self.composite = composite
        self.allowed = allowed
        self.request = request
        self.worker = worker
    }

    /// `onCapture` runs on the worker after each successful capture.
    @discardableResult
    public func begin(onCapture: (@Sendable () -> Void)? = nil) -> CaptureSession {
        lock.withLock {
            nextIdent += 1
            let session = CaptureSession(ident: nextIdent, onCapture: onCapture)
            self.session = session
            return session
        }
    }

    /// Called on the event tap thread: no work beyond a queue hop.
    public func submit(_ stroke: Stroke) {
        guard let session = lock.withLock({ self.session }), session.claim(stroke.number) else { return }
        worker.async { self.work(session, stroke) }
    }

    /// Closes the session at key-up. Any mark the tap thread hadn't handed over yet is
    /// queued now.
    @discardableResult
    public func finish(_ strokes: [Stroke]) -> CaptureSession? {
        guard let session = lock.withLock({ () -> CaptureSession? in
            defer { self.session = nil }
            return self.session
        }) else { return nil }
        for stroke in session.expect(strokes) {
            worker.async { self.work(session, stroke) }
        }
        return session
    }

    private func permissionOK(_ session: CaptureSession) -> Bool {
        if allowed() { return true }
        session.notePermissionMissing()
        if !requested {
            requested = true
            log("Screen Recording permission is missing, so marks can't be captured. Asking macOS for it; allow Voice Type Native in System Settings > Privacy & Security > Screen & System Audio Recording, then run voice-type-native restart.")
            request()
        }
        return false
    }

    private func work(_ session: CaptureSession, _ stroke: Stroke) {
        if permissionOK(session) {
            do {
                try captureInto(session, stroke)
            } catch {
                log("Mark \(stroke.number) capture failed: \(error.localizedDescription)")
            }
        }
        session.settle(stroke.number)
    }

    /// Captures one mark and draws it, plus any earlier marks on the same window, onto that
    /// capture.
    private func captureInto(_ session: CaptureSession, _ stroke: Stroke) throws {
        guard let (raw, target) = try capture(stroke) else {
            log("Mark \(stroke.number): nothing to capture.")
            return
        }
        let key = target.groupKey
        let group = key.flatMap { session.groups[$0] }
        let strokes = ((group?.strokes ?? []) + [stroke]).sorted { $0.number < $1.number }
        let png = try composite(raw, target.rect, strokes)
        let path = try store.save(png, number: strokes[0].number)
        // Before the path is published, so it has happened by the time finalisation sees it.
        session.onCapture?()
        let numbers = strokes.map(\.number)
        let keepOld = session.record(path, for: numbers)
        if let key { session.groups[key] = CaptureSession.Group(strokes: strokes, path: path) }
        log("Mark \(stroke.number) (\(stroke.kind.rawValue)) captured from \(target.description): \(path)")
        if let group {
            log("Marks \(numbers) share \(target.description): one screenshot.")
            if !keepOld { store.discard(group.path) }
        }
    }
}

/// The marks from one dictation, handed from key-up to finalisation. Used on the finalise
/// lane only.
public final class DictationMarks: @unchecked Sendable {
    public let strokes: [Stroke]
    public let session: CaptureSession?
    /// When audio sample 0 was captured, on the strokes' clock, to turn mark times into
    /// audio times.
    public let audioOrigin: Double
    /// How long key-up waits for the screenshots, at most.
    public static let captureWait = 4.0
    /// Marks are captured one at a time, so a dictation with several still queued at key-up
    /// needs longer than one with a single mark.
    public static let captureWaitPerMark = 1.0
    public var waitTimeout = DictationMarks.captureWait
    public var waitPerMark = DictationMarks.captureWaitPerMark
    private let log: ((String) -> Void)?
    private var shots: [(number: Int, path: String)]?

    public init(strokes: [Stroke], session: CaptureSession?, audioOrigin: Double, log: ((String) -> Void)? = nil) {
        self.strokes = strokes
        self.session = session
        self.audioOrigin = audioOrigin
        self.log = log
    }

    /// (number, path) for every mark that was captured, waiting once.
    func collect() -> [(number: Int, path: String)] {
        if let shots { return shots }
        let got = session?.wait(timeout: waitTimeout + waitPerMark * Double(strokes.count)) ?? []
        let missing = Set(strokes.map(\.number)).subtracting(got.map(\.number)).sorted()
        if !missing.isEmpty { log?("Mark(s) \(missing) have no screenshot to paste.") }
        shots = got
        return got
    }

    /// Every captured mark's number, for the "[n]" markers in the text.
    public func numbers() -> [Int] { collect().map(\.number) }

    /// One file per screenshot to paste, in order of each one's lowest mark number. Marks on
    /// the same window share a file.
    public func imagePaths() -> [String] {
        var paths: [String] = []
        for (_, path) in collect() where !paths.contains(path) { paths.append(path) }
        return paths
    }

    public var permissionMissing: Bool { session?.permissionMissing ?? false }

    /// False once it's certain no mark will have a screenshot (no Screen Recording, or every
    /// capture already failed), so there's no point timing the words for markers.
    public var mayHaveScreenshots: Bool { session?.mayHaveScreenshots ?? false }

    /// At least one mark has been captured already, even if others are still going.
    public var hasScreenshot: Bool { session?.hasScreenshot ?? false }

    /// When each numbered mark was finished, in seconds of audio.
    public func audioTimes(_ numbers: [Int]) -> [Double] {
        let ended = Dictionary(strokes.map { ($0.number, $0.endedAt) }, uniquingKeysWith: { a, _ in a })
        return numbers.map { (ended[$0] ?? audioOrigin) - audioOrigin }
    }
}
