import AppKit
import QuartzCore
import VoiceTypeCore

// The pill at the bottom of the screen, ported from appkit_overlay.py: a borderless panel
// that never takes focus or clicks, on every Space and over full-screen apps. What it says
// and when is PillController's job in VoiceTypeCore; this only draws.

private enum PillLayout {
    static let width: CGFloat = 220
    static let topRow: CGFloat = 26
    static let previewHeight: CGFloat = 36
    static let paddingX: CGFloat = 12
    static let paddingY: CGFloat = 8
    static let accentWidth: CGFloat = 4
    static let labelWidth: CGFloat = 50
    static let feedbackLabelWidth: CGFloat = 124
    static let barsWidth: CGFloat = 46
    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 3
    static let bottomMargin: CGFloat = 20
    static let height = topRow + paddingY * 2 + previewHeight + 2
}

extension PillColor {
    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        case .orange: return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        case .green: return NSColor(calibratedRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The REC bars, or the tick in their place once a paste lands.
private final class BarsView: NSView {
    var heights = [Double](repeating: PillController.barMinHeight, count: PillController.barCount) { didSet { needsDisplay = true } }
    var color = PillColor.red.nsColor { didSet { needsDisplay = true } }
    var checkProgress: Double? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.set()
        if let checkProgress {
            let p = PillController.checkmarkPoints(checkProgress)
            let path = NSBezierPath()
            path.lineWidth = 3
            path.move(to: NSPoint(x: p[0], y: p[1]))
            path.line(to: NSPoint(x: p[2], y: p[3]))
            path.line(to: NSPoint(x: p[4], y: p[5]))
            path.stroke()
            return
        }
        let maxY = bounds.height - 2
        for (i, height) in heights.enumerated() {
            let x = CGFloat(i) * (PillLayout.barWidth + PillLayout.barGap)
            let rect = NSRect(x: x, y: maxY - CGFloat(height), width: PillLayout.barWidth, height: CGFloat(height))
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class PillPanel: PillSurface {
    private let panel: NSPanel
    private let accent = NSView()
    private let dot = NSTextField(labelWithString: "\u{25CF}")
    private let label = NSTextField(labelWithString: " REC")
    private let bars = BarsView()
    private let preview = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: PillLayout.width, height: PillLayout.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.96)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: PillLayout.width, height: PillLayout.height))
        panel.contentView = content
        accent.wantsLayer = true
        dot.font = .systemFont(ofSize: 11)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byWordWrapping
        for view in [accent, dot, label, bars, preview] as [NSView] { content.addSubview(view) }
        layout(wide: false)
    }

    private func layout(wide: Bool) {
        let width = PillLayout.width, height = PillLayout.height
        accent.frame = NSRect(x: 0, y: 0, width: PillLayout.accentWidth, height: height)
        dot.frame = NSRect(x: PillLayout.paddingX, y: 13, width: 14, height: 16)
        label.frame = NSRect(x: PillLayout.paddingX + 18, y: 11, width: wide ? PillLayout.feedbackLabelWidth : PillLayout.labelWidth, height: 18)
        bars.frame = NSRect(x: width - PillLayout.paddingX - PillLayout.barsWidth, y: 8, width: PillLayout.barsWidth, height: 24)
        preview.frame = NSRect(x: PillLayout.paddingX, y: PillLayout.topRow + PillLayout.paddingY, width: width - PillLayout.paddingX * 2,
                               height: PillLayout.previewHeight)
    }

    func present(_ appearance: PillAppearance, repositionOnly: Bool) {
        label.stringValue = appearance.label
        preview.stringValue = appearance.preview
        let color = appearance.color.nsColor
        accent.layer?.backgroundColor = color.cgColor
        dot.textColor = color
        bars.color = color
        if appearance.wideLabel { bars.heights = [Double](repeating: PillController.barMinHeight, count: PillController.barCount) }
        layout(wide: appearance.wideLabel)
        position()
        if !repositionOnly { panel.orderFrontRegardless() }
    }

    /// Bottom centre of the main screen's visible area, as Python placed it.
    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.minX + visible.width / 2 - PillLayout.width / 2, y: visible.minY + PillLayout.bottomMargin,
                           width: PillLayout.width, height: PillLayout.height)
        panel.setFrame(frame, display: true)
    }

    func hide() { panel.orderOut(nil) }
    func setAlpha(_ alpha: Double) { panel.alphaValue = alpha }

    func setBarHeights(_ heights: [Double], color: PillColor) {
        bars.color = color.nsColor
        bars.heights = heights
    }

    func setCheckProgress(_ progress: Double?) { bars.checkProgress = progress }
}

/// The pill for the controller, which calls from its own queue: everything hops to the
/// main thread. Also runs the 30 fps animation while the pill shows.
final class MainThreadPill: PillPresenting, @unchecked Sendable {
    private var controller: PillController!
    private var timer: Timer?
    private let level: () -> Double

    init(level: @escaping () -> Double) {
        self.level = level
        DispatchQueue.main.async { [self] in
            controller = PillController(surface: PillPanel(), scheduler: QueueExecutor(.main), now: { CACurrentMediaTime() },
                                        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
        }
    }

    private func onMain(_ work: @escaping (PillController) -> Void) {
        DispatchQueue.main.async { [self] in
            work(controller)
            animate()
        }
    }

    private func animate() {
        if controller.isVisible, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.controller.animationFrame(level: self.level(), time: CACurrentMediaTime())
                if !self.controller.isVisible {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func showRecording(_ preview: String) { onMain { $0.showRecording(preview) } }
    func showSecondsLeft(_ seconds: Int) { onMain { $0.showSecondsLeft(seconds) } }
    func showProcessing(_ preview: String) { onMain { $0.showProcessing(preview) } }
    func showDone(words: Int) { onMain { $0.showDone(words: words) } }
    func showDone(words: Int, shots: Int) { onMain { $0.showDone(words: words, shots: shots) } }
    func showScreenRecordingHint() { onMain { $0.showScreenRecordingHint() } }
    func showPasteFailed(_ miss: FocusMiss?) { onMain { $0.showPasteFailed(miss) } }
    func showClipboardNotKept() { onMain { $0.showClipboardNotKept() } }
    func showRecovered(count: Int, seconds: Double) { onMain { $0.showRecovered(count: count, seconds: seconds) } }
    func hide() { onMain { $0.hide() } }
}
