import Foundation

/// The mouse tap's on/off switch and the session around the ink tracker, ported from the
/// module-level drawing functions in platform_mac.py. The mouse tap is only on while a
/// session (or an owed mouse-up) needs it, so normal mouse use never goes through Voice Type.
///
/// Threads: `begin` and `end` come from the controller's queue; `keyReleased`,
/// `handleMouse`, `mouseTapDisabled` and `reset` from the event tap's thread; `watchdog`
/// from a timer. One lock (Python's `_ink_lock`) orders the session against the key, so a
/// session never starts after its key-up has been handled, and the tap is switched under it
/// so a late "off" can't undo a fresh "on".
///
/// Python's `keep_drawing_session` (a release and re-press between two of its 10 ms polls
/// looked like one long press) has no counterpart: the native controller sees every key
/// change, so a release always ends the dictation and a re-press never continues it.
public final class DrawingSession: @unchecked Sendable {
    public let tracker: InkTracker
    private let lock = NSLock()
    private var setTap: ((Bool) -> Void)?
    private var tapOn = false
    private var isKeyDown: () -> Bool = { false }
    /// Asked to start the watchdog timer whenever the tap goes on.
    private var armWatchdog: () -> Void = {}

    public init(tracker: InkTracker) {
        self.tracker = tracker
    }

    /// Wires up the mouse tap once it exists. Without it (it couldn't be created) drawing
    /// is off and every dictation goes as before.
    public func attach(setTap: @escaping (Bool) -> Void, isKeyDown: @escaping () -> Bool, armWatchdog: @escaping () -> Void) {
        lock.withLock {
            self.setTap = setTap
            self.isKeyDown = isKeyDown
            self.armWatchdog = armWatchdog
        }
    }

    public var isAvailable: Bool { lock.withLock { setTap != nil } }

    /// Starts a session for a recording that has just started, after the microphone, so
    /// drawing never delays it. Called on the controller's queue, never on the tap thread.
    /// If the key has already gone up again, nothing starts.
    public func begin() -> Bool {
        let started: Bool = lock.withLock {
            guard setTap != nil, isKeyDown() else { return false }
            tracker.begin()
            switchTapLocked(true)
            return true
        }
        if started { armWatchdog() }
        return started
    }

    /// The hotkey just went up, on the tap thread: stop drawing right there rather than on
    /// the controller's next turn, so a click straight after release always reaches the app.
    public func keyReleased() {
        lock.withLock {
            guard tracker.needsTap else { return }
            if !tracker.end() { switchTapLocked(false) }
        }
    }

    /// Ends the session (if the tap thread hasn't already) and takes its marks.
    public func end() -> [Stroke] {
        lock.withLock {
            if !tracker.end() { switchTapLocked(false) }
        }
        return tracker.takeStrokes()
    }

    /// Stops drawing and lets every mouse event through again: a keyboard tap timeout (the
    /// key-up may be among the lost events), a wake, or the tap going away.
    public func reset() {
        lock.withLock {
            tracker.reset()
            switchTapLocked(false)
        }
    }

    /// One left-button event on the tap thread. Returns whether to swallow it.
    public func handleMouse(_ kind: InkTracker.MouseKind, _ x: Double, _ y: Double) -> Bool {
        let (swallow, keep) = tracker.handleMouse(kind, x, y)
        if !keep {
            // Checked again under the lock: a session may have begun since.
            lock.withLock { if !tracker.needsTap { switchTapLocked(false) } }
        }
        return swallow
    }

    /// macOS turned the mouse tap off (a timeout, or certain user input). Button events
    /// went straight to the app meanwhile, so who owns the button isn't known any more: let
    /// it go, then come back only if a session still needs the tap.
    public func mouseTapDisabled() {
        tracker.forgetButton()
        lock.withLock {
            tapOn = false
            if tracker.needsTap { switchTapLocked(true) }
        }
    }

    /// Belt and braces, a few times a second while the tap is on: the mouse must never stay
    /// captured. The tap thread normally ends the session at key-up; if the key state was
    /// reset some other way, or an owed mouse-up never came, this lets the mouse go.
    /// Returns whether there's still anything to watch.
    ///
    /// The key is read and the session ended under one hold of the lock. Read under the lock
    /// and acted on after it, a key-up seen just before a fast re-press could end the session
    /// begin() had just started for it, and the rest of that dictation's clicks would reach
    /// the app (as Control-clicks, with Right Control).
    @discardableResult
    public func watchdog() -> Bool {
        lock.withLock {
            if tracker.isActive {
                if !isKeyDown() && !tracker.end() { switchTapLocked(false) }
            } else if tracker.expirePendingUp() && !tracker.needsTap {
                switchTapLocked(false)
            }
            return tapOn || tracker.needsTap
        }
    }

    private func switchTapLocked(_ on: Bool) {
        guard let setTap else { return }
        // Only talk to the window server about "off" when it's actually on.
        if !on && !tapOn { return }
        setTap(on)
        tapOn = on
    }
}
