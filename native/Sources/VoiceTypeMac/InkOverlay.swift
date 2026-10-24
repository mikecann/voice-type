import AppKit
import VoiceTypeCore

/// The live ink while drawing, ported from appkit_ink.py: a transparent, click-through panel
/// above normal windows on each display the ink reaches. The panels never become key or main
/// and the app stays an accessory, so the frontmost app (where the paste goes) never changes.
/// They're left out of screen captures, so the ink never lands in a desktop-region screenshot
/// twice.
///
/// The event tap only records points; this picks them up at 60 fps from the tracker's
/// snapshot while a session is live, and stops polling once the ink is gone. A display's
/// panel is made when ink first reaches it and closed once the ink has gone, so their
/// full-screen backing stores (about 31 MB for the laptop screen, 59 MB for a 5K display)
/// only exist while there's something on them, and each frame redraws only the part of the
/// display where the ink changed. Main thread only.
final class InkOverlay {
    private struct Layer {
        let panel: NSPanel
        let view: InkView
    }

    private let tracker: InkTracker
    /// The displays (AppKit frames, and Quartz ones for the ink) when the ink appeared.
    private var frames: [NSRect] = []
    private var screens: [MarkRect] = []
    /// By index into `screens`, only for displays with ink on them.
    private var layers: [Int: Layer] = [:]
    private var version = -1
    private var timer: Timer?

    init(tracker: InkTracker) { self.tracker = tracker }

    /// A drawing session has started.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let snapshot = tracker.snapshot()
        let hasInk = !snapshot.strokes.isEmpty || snapshot.current != nil
        if snapshot.version != version {
            version = snapshot.version
            if hasInk { show(snapshot.strokes, snapshot.current) } else { clear() }
        }
        if !hasInk && !tracker.isActive {
            clear()
            timer?.invalidate()
            timer = nil
        }
    }

    private func show(_ strokes: [Stroke], _ current: [MarkPoint]?) {
        let screenFrames = NSScreen.screens.map(\.frame)
        if screenFrames != frames {
            // Displays came or went, or the ink is new: start from nothing.
            clear()
            frames = screenFrames
            // Quartz flips around the primary display's height (screens[0]).
            let primaryHeight = screenFrames.first?.height ?? 0
            screens = screenFrames.map { ScreenMarks.appKitFrameToQuartz(MarkRect($0.origin.x, $0.origin.y, $0.width, $0.height), primaryHeight: primaryHeight) }
        }
        for (index, screen) in screens.enumerated() {
            let content = InkLayerContent(strokes: strokes, current: current, screen: screen)
            if let layer = layers[index] {
                layer.view.show(content)
            } else if !content.isEmpty {
                let layer = makeLayer(frames[index])
                layers[index] = layer
                layer.view.show(content)
                layer.panel.orderFrontRegardless()
            }
        }
    }

    /// Closes every panel, which frees its backing store.
    private func clear() {
        for layer in layers.values {
            layer.panel.orderOut(nil)
            layer.panel.close()
        }
        layers = [:]
        frames = []
        screens = []
    }

    private func makeLayer(_ frame: NSRect) -> Layer {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // This holds the only reference, so closing it and dropping the layer frees it.
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = InkView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        return Layer(panel: panel, view: view)
    }
}

private final class InkView: NSView {
    private var content = InkLayerContent()

    // Top-left origin, like Quartz global coordinates.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Redraws only what changed on this display, if anything did.
    func show(_ new: InkLayerContent) {
        let dirty = new.dirtyRect(since: content)
        content = new
        if let dirty { setNeedsDisplay(NSRect(x: dirty.x, y: dirty.y, width: dirty.width, height: dirty.height)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        InkRenderer.draw(content.marks, in: context, style: .screen)
        if let line = content.line {
            InkRenderer.drawLine(line, width: ScreenMarks.inkWidth, in: context)
        }
    }
}
