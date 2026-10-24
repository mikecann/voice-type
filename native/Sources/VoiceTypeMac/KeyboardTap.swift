import CoreGraphics
import Foundation
import Synchronization
import VoiceTypeCore

/// The push-to-talk keyboard tap, on its own thread and run loop, ported from
/// _run_cg_event_tap in platform_mac.py.
///
/// An active (not listen-only) session tap, so F12 and Right Control can be swallowed and
/// macOS never acts on them. The callback only updates the key state and passes a change on;
/// no AppKit, logging or waiting, since a slow callback gets the tap disabled by the system.
/// If macOS does disable it (a timeout, or certain user input), it's switched straight back
/// on and treated as a key-up, because the real key-up may be among the events it lost and
/// push-to-talk must never stay stuck on.
///
/// While Voice Type can't take dictation (paused, no model, given up after restarts), the
/// keys still reach the controller but aren't swallowed, so F12 and Right Control keep working
/// as normal keys. While it's starting up they're swallowed, as in Python, where the readiness
/// notice started the tap: a press then shows why nothing is recording.
///
/// The drawing tap shares this thread's run loop but starts disabled: it watches only left
/// mouse down, drag and up, and is only on while a drawing session needs it, so normal mouse
/// use never goes through Voice Type. Plain movement isn't in its mask at all, so the cursor
/// moves as usual even while drawing. Its callback only records points (DrawingSession).
/// Any failure creating it just turns drawing off; it never costs the hotkey tap.
final class KeyboardTap: @unchecked Sendable {
    enum Status: String { case notStarted = "not-started", running = "event-tap", waitingForPermission = "waiting-for-permission" }

    private var keys = HotkeyState()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    /// Called on the tap thread with each change; it must only hand the change on.
    private let onChange: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var status_: Status = .notStarted
    /// Read on the tap thread at each press, so no lock.
    private let swallowing = Atomic<Bool>(true)
    /// The hotkey's state as the tap thread last saw it, for the controller's queue to read
    /// when a drawing session starts.
    private let keyDown = Atomic<Bool>(false)
    private let drawing: DrawingSession?
    private var mousePort: CFMachPort?
    private let log: @Sendable (String) -> Void

    init(drawing: DrawingSession? = nil, log: @escaping @Sendable (String) -> Void = { _ in }, onChange: @escaping @Sendable (Bool) -> Void) {
        self.drawing = drawing
        self.log = log
        self.onChange = onChange
    }

    var status: Status { lock.withLock { status_ } }

    /// Whether presses from now on are swallowed. A key already down keeps its press's choice.
    func setSwallowing(_ on: Bool) { swallowing.store(on, ordering: .relaxed) }

    /// Creates the tap. Fails (returns false) without Accessibility and Input Monitoring; the
    /// app tries again every couple of seconds until they're granted.
    func start() -> Bool {
        if status == .running { return true }
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [self] in
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .defaultMode)
            CGEvent.tapEnable(tap: port, enable: true)
            self.port = port
            self.runLoop = loop
            self.createMouseTap(on: loop)
            created = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "voice-type-hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        lock.withLock { status_ = created ? .running : .waitingForPermission }
        if created { self.thread = thread }
        return created
    }

    private func createMouseTap(on loop: CFRunLoop) {
        guard let drawing else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let mouse = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: CGEventMask(mask), callback: mouseCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("Mouse event tap unavailable; drawing while dictating is off.")
            return
        }
        CGEvent.tapEnable(tap: mouse, enable: false)
        CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, mouse, 0), .defaultMode)
        mousePort = mouse
        let watchdog = DrawingWatchdog(drawing: drawing)
        drawing.attach(setTap: { on in CGEvent.tapEnable(tap: mouse, enable: on) },
                       isKeyDown: { [weak self] in self?.keyDown.load(ordering: .relaxed) ?? false },
                       armWatchdog: { watchdog.arm() })
    }

    /// Turns the tap off for good, before the app quits.
    func stop() {
        guard let loop = runLoop, let port else { return }
        drawing?.reset()
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let mousePort {
            CGEvent.tapEnable(tap: mousePort, enable: false)
            CFMachPortInvalidate(mousePort)
        }
        CFRunLoopStop(loop)
        self.port = nil
        mousePort = nil
        runLoop = nil
        lock.withLock { status_ = .notStarted }
    }

    /// After a wake: forget the keys, as Python did, so a key-up lost in sleep can't leave
    /// push-to-talk on, and let the mouse go. Runs on the tap thread.
    func reset() {
        guard let loop = runLoop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            let wasDown = keys.isDown
            keys.reset()
            keyDown.store(false, ordering: .relaxed)
            drawing?.reset()
            if wasDown { onChange(false) }
        }
        CFRunLoopWakeUp(loop)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            let wasDown = keys.isDown
            keys.reset()
            keyDown.store(false, ordering: .relaxed)
            // The key-up may be among the lost events, so the mouse mustn't stay a pen.
            drawing?.reset()
            if wasDown { onChange(false) }
            return Unmanaged.passUnretained(event)
        }
        let kind: HotkeyState.EventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        let wasDown = keys.isDown
        let disposition = keys.handle(kind, keycode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue,
                                      swallowing: swallowing.load(ordering: .relaxed))
        guard disposition != .notOurs else { return Unmanaged.passUnretained(event) }
        // Key repeats come through as more key-downs; only real changes go on.
        if keys.isDown != wasDown {
            keyDown.store(keys.isDown, ordering: .relaxed)
            // Stop drawing the moment the key goes up, right here rather than when the
            // controller gets to it, so a click straight after release reaches the app.
            if !keys.isDown { drawing?.keyReleased() }
            onChange(keys.isDown)
        }
        return disposition == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    fileprivate func handleMouse(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let drawing else { return Unmanaged.passUnretained(event) }
        let kind: InkTracker.MouseKind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            drawing.mouseTapDisabled()
            return Unmanaged.passUnretained(event)
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .drag
        case .leftMouseUp: kind = .up
        default: return Unmanaged.passUnretained(event)
        }
        let location = event.location
        return drawing.handleMouse(kind, location.x, location.y) ? nil : Unmanaged.passUnretained(event)
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    Unmanaged<KeyboardTap>.fromOpaque(userInfo!).takeUnretainedValue().handle(type, event)
}

private let mouseCallback: CGEventTapCallBack = { _, type, event, userInfo in
    Unmanaged<KeyboardTap>.fromOpaque(userInfo!).takeUnretainedValue().handleMouse(type, event)
}

/// Calls DrawingSession.watchdog a few times a second while the mouse tap is on, so the
/// mouse can never stay captured, and stops once there's nothing left to watch.
final class DrawingWatchdog: @unchecked Sendable {
    private let drawing: DrawingSession
    private let queue = DispatchQueue(label: "voice-type.drawing-watchdog", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(drawing: DrawingSession) { self.drawing = drawing }

    func arm() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self, !self.drawing.watchdog() else { return }
                self.timer?.cancel()
                self.timer = nil
            }
            self.timer = timer
            timer.resume()
        }
    }
}
