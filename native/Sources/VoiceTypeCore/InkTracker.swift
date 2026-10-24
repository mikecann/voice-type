import Foundation

/// Turns mouse events into strokes while a drawing session is live. Ported from
/// MacInkTracker in platform_mac.py, with every edge case that keeps the mouse from getting
/// stuck: a drag already under way at key-down belongs to the app, a mouse-up owed after the
/// key went up mid-drag is given up after 5 s, a press still owed from the last dictation
/// stays ours in the next, and a tap timeout gives up the button.
///
/// `handleMouse` runs on the event tap's thread, so it only takes a lock and appends a
/// point. Finished strokes go to `onStroke` outside the lock (the capture worker's queue).
public final class InkTracker: @unchecked Sendable {
    public enum MouseKind: Sendable { case down, drag, up }

    /// A mouse-up still owed to us after the key went up mid-drag is given up on after this
    /// long, so the mouse can never stay swallowed.
    public static let pendingMouseUpTimeout = 5.0
    /// Drag samples closer than this to the previous one are skipped (points).
    public static let minSampleSpacing = 1.0

    private let clock: () -> Double
    private let maxMarks: Int
    private let lock = NSLock()
    private var onStroke: ((Stroke) -> Void)?
    private var active = false
    private var current: [MarkPoint]?
    private var currentStarted = 0.0
    private var strokes: [Stroke] = []
    private var recorded = 0
    private var pendingUpSince: Double?
    /// Whether the button is down on a press we swallowed. A drag that was already under way
    /// at key-down belongs to the app, not to us.
    private var holdingDown = false
    private var version = 0

    public init(clock: @escaping () -> Double, maxMarks: Int = ScreenMarks.maxMarks, onStroke: ((Stroke) -> Void)? = nil) {
        self.clock = clock
        self.maxMarks = maxMarks
        self.onStroke = onStroke
    }

    /// Who gets each finished mark (the capture worker), set once at startup.
    public func setOnStroke(_ handler: ((Stroke) -> Void)?) { lock.withLock { onStroke = handler } }

    public func begin() {
        lock.withLock {
            active = true
            current = nil
            strokes = []
            recorded = 0
            // A press swallowed in the last session whose mouse-up hasn't come yet is still
            // ours: the app never saw its mouse-down.
            holdingDown = pendingUpSince != nil
            pendingUpSince = nil
            version += 1
        }
    }

    /// Stops claiming the button after the tap missed events. While the tap was off the app
    /// may have seen a mouse-up and a fresh mouse-down, so swallowing the next mouse-up could
    /// leave it holding a button. The mark in progress ends where it got to.
    public func forgetButton() {
        let finished: Stroke? = lock.withLock {
            let stroke = current != nil ? finishLocked() : nil
            holdingDown = false
            pendingUpSince = nil
            version += 1
            return stroke
        }
        announce(finished)
    }

    /// Ends the session. Returns whether the tap must stay on for an owed mouse-up.
    @discardableResult
    public func end() -> Bool {
        let (finished, keep): (Stroke?, Bool) = lock.withLock {
            guard active else { return (nil, pendingUpSince != nil) }
            active = false
            var stroke: Stroke?
            if holdingDown {
                // Key released mid-drag: the mark ends here, but the app never saw the
                // mouse-down, so its mouse-up is ours too.
                if current != nil { stroke = finishLocked() }
                holdingDown = false
                pendingUpSince = clock()
            }
            version += 1
            return (stroke, pendingUpSince != nil)
        }
        announce(finished)
        return keep
    }

    /// Forgets everything and stops swallowing, after a keyboard tap timeout or a wake.
    public func reset() {
        lock.withLock {
            active = false
            current = nil
            strokes = []
            pendingUpSince = nil
            holdingDown = false
            version += 1
        }
    }

    public var isActive: Bool { lock.withLock { active } }

    public var needsTap: Bool { lock.withLock { active || pendingUpSince != nil } }

    /// Drops an owed mouse-up that never came. Returns whether the tap can go.
    public func expirePendingUp() -> Bool {
        lock.withLock {
            if active { return false }
            if let since = pendingUpSince, clock() - since > Self.pendingMouseUpTimeout { pendingUpSince = nil }
            return pendingUpSince == nil
        }
    }

    /// One left-button event. Returns whether to swallow it, and whether the tap is still
    /// needed (false turns it off).
    public func handleMouse(_ kind: MouseKind, _ x: Double, _ y: Double) -> (swallow: Bool, keep: Bool) {
        var finished: Stroke?
        let result: (Bool, Bool) = lock.withLock {
            if !active {
                guard pendingUpSince != nil else { return (false, false) }
                switch kind {
                case .down:
                    // A fresh click after the session: the owed mouse-up is lost somewhere,
                    // so let this click through as normal.
                    pendingUpSince = nil
                    return (false, false)
                case .up:
                    pendingUpSince = nil
                    return (true, false)
                case .drag:
                    return (true, true)
                }
            }
            if kind != .down && !holdingDown {
                // The app saw this drag's mouse-down before the key went down, so let the
                // rest of it through.
                return (false, true)
            }
            switch kind {
            case .down:
                holdingDown = true
                if current != nil { finished = finishLocked() }
                if recorded < maxMarks {
                    current = [MarkPoint(x, y)]
                    currentStarted = clock()
                }
            case .drag:
                if let last = current?.last, abs(x - last.x) + abs(y - last.y) >= Self.minSampleSpacing {
                    current!.append(MarkPoint(x, y))
                }
            case .up:
                holdingDown = false
                if current != nil {
                    current!.append(MarkPoint(x, y))
                    finished = finishLocked()
                }
            }
            version += 1
            return (true, true)
        }
        announce(finished)
        return result
    }

    private func finishLocked() -> Stroke {
        recorded += 1
        let stroke = Stroke(points: current!, startedAt: currentStarted, endedAt: clock(), number: recorded)
        strokes.append(stroke)
        current = nil
        return stroke
    }

    private func announce(_ stroke: Stroke?) {
        // Outside the lock: the handler only queues the stroke.
        guard let stroke, let handler = lock.withLock({ onStroke }) else { return }
        handler(stroke)
    }

    public func takeStrokes() -> [Stroke] {
        lock.withLock {
            defer {
                strokes = []
                version += 1
            }
            return strokes
        }
    }

    /// (version, finished strokes, in-progress points), for drawing the live ink.
    public func snapshot() -> (version: Int, strokes: [Stroke], current: [MarkPoint]?) {
        lock.withLock { (version, strokes, current) }
    }
}
