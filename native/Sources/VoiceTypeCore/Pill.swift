import Foundation

/// What the pill at the bottom of the screen says, ported from the Overlay class in
/// voice-type.py and appkit_overlay.py. The drawing lives in the app; this decides what to
/// draw and when, so the timings can be tested.
///
/// REC is red with live bars, "..." is orange with a slow sweep while Whisper runs. A paste
/// that landed turns the pill green with "N words" and a tick that draws itself in 0.12 s,
/// holds 0.22 s and fades over 0.14 s. A paste that didn't land says "On your clipboard.
/// ⌘V to paste" for 1.6 s and goes without a fade. A paste that landed when macOS wouldn't
/// let the old clipboard be read says so once, for 4 s. Reduce Motion skips the tick
/// animation and the fade.
public enum PillState: String, Sendable {
    case rec
    case processing
    case done
    case pasteFailed = "paste_failed"
    case hint
    /// Pasted, but the old clipboard couldn't be read, so it's gone.
    case clipboardNotKept = "clipboard_not_kept"
}

public enum PillColor: Sendable, Equatable {
    case red, orange, green
}

public struct PillAppearance: Equatable, Sendable {
    public var state: PillState
    public var label: String
    public var preview: String
    public var color: PillColor
    /// Feedback labels need more room; the panel itself never changes width.
    public var wideLabel: Bool

    public init(state: PillState, text: String) {
        self.state = state
        switch state {
        case .rec: label = " REC"
        case .done: label = " \(text)"
        case .pasteFailed: label = " Clipboard"
        case .hint: label = " No screenshots"
        case .processing: label = " ..."
        case .clipboardNotKept: label = " Pasted"
        }
        preview = state == .done ? "" : text
        color = state == .done ? .green : state == .rec ? .red : .orange
        wideLabel = state == .done || state.isNotice
    }
}

/// The parts of the pill that touch AppKit. Called on the main thread only.
extension PillState {
    /// Feedback that holds without the tick or a fade.
    var isNotice: Bool { self == .pasteFailed || self == .hint || self == .clipboardNotKept }
}

public protocol PillSurface: AnyObject {
    /// Shows (or updates, if already showing) the pill at the bottom centre of the screen.
    func present(_ appearance: PillAppearance, repositionOnly: Bool)
    func hide()
    func setAlpha(_ alpha: Double)
    func setBarHeights(_ heights: [Double], color: PillColor)
    /// Nil draws the bars; a number draws the tick that far along.
    func setCheckProgress(_ progress: Double?)
}

public protocol Cancellable: AnyObject { func cancel() }

/// Runs work later on the pill's thread (the main thread in the app).
public protocol Scheduler: AnyObject {
    @discardableResult func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable
}

public final class PillController {
    public static let barCount = 7
    public static let barMinHeight = 3.0
    public static let barMaxHeight = 20.0
    public static let doneHoldSeconds = 0.22
    public static let failureHoldSeconds = 1.6
    public static let clipboardNoticeHoldSeconds = 4.0
    public static let fadeSeconds = 0.14
    public static let tickDrawSeconds = 0.12

    private let surface: PillSurface
    private let scheduler: Scheduler
    private let now: () -> Double
    private let reduceMotion: () -> Bool

    public private(set) var state: PillState?
    public private(set) var isVisible = false
    private var feedbackTimer: Cancellable?
    private var feedbackStarted = 0.0
    private var fadeStarted = 0.0
    private var reducedMotion = false
    public private(set) var barHeights = [Double](repeating: barMinHeight, count: barCount)

    public init(surface: PillSurface, scheduler: Scheduler, now: @escaping () -> Double, reduceMotion: @escaping () -> Bool) {
        self.surface = surface
        self.scheduler = scheduler
        self.now = now
        self.reduceMotion = reduceMotion
    }

    public func showRecording(_ preview: String = "") { show(.rec, preview) }
    public func showProcessing(_ preview: String = "") { show(.processing, preview) }

    public func showDone(words: Int) {
        show(.done, "\(words) word\(words == 1 ? "" : "s")")
    }

    public func showPasteFailed() { show(.pasteFailed, "On your clipboard. \u{2318}V to paste") }

    public func showClipboardNotKept() { show(.clipboardNotKept, "Allow Paste from other apps to keep your clipboard") }

    public func hide() {
        cancelFeedback()
        surface.hide()
        isVisible = false
        state = nil
    }

    private func show(_ newState: PillState, _ text: String) {
        cancelFeedback()
        surface.setAlpha(1)
        state = newState
        let feedback = newState == .done || newState.isNotice
        if feedback {
            reducedMotion = reduceMotion()
            feedbackStarted = now()
            barHeights = [Double](repeating: Self.barMinHeight, count: Self.barCount)
        }
        surface.setCheckProgress(newState == .done ? (reducedMotion ? 1 : 0) : nil)
        surface.present(PillAppearance(state: newState, text: text), repositionOnly: isVisible)
        isVisible = true
        if feedback {
            let hold = newState == .done ? Self.doneHoldSeconds : newState == .clipboardNotKept ? Self.clipboardNoticeHoldSeconds : Self.failureHoldSeconds
            feedbackTimer = scheduler.schedule(after: hold) { [weak self] in self?.startFeedbackFade() }
        }
    }

    private func cancelFeedback() {
        feedbackTimer?.cancel()
        feedbackTimer = nil
    }

    private func startFeedbackFade() {
        feedbackTimer = nil
        if reducedMotion || state?.isNotice == true {
            hide()
            return
        }
        fadeStarted = now()
        fadeStep()
    }

    private func fadeStep() {
        feedbackTimer = nil
        let alpha = max(0, 1 - (now() - fadeStarted) / Self.fadeSeconds)
        if alpha <= 0.001 {
            // Hidden right here rather than through a queued hide, which could land after
            // the next recording's REC and take it down with it.
            hide()
            return
        }
        surface.setAlpha(alpha)
        feedbackTimer = scheduler.schedule(after: 0.016) { [weak self] in self?.fadeStep() }
    }

    /// One animation frame, about 30 a second while the pill shows. `level` is the RMS of the
    /// last bit of audio, which drives the REC bars.
    public func animationFrame(level: Double, time t: Double) {
        guard isVisible, let state else { return }
        switch state {
        case .done:
            surface.setCheckProgress(reducedMotion ? 1 : min(1, (now() - feedbackStarted) / Self.tickDrawSeconds))
            return
        case .rec:
            // A typical microphone RMS is 0.01 to 0.07.
            let loud = min(level * 14, 1)
            for i in 0..<Self.barCount {
                let wave = (sin(t * (4.5 + Double(i) * 0.4) + Double(i) * 0.75) + 1) / 2
                let target = Self.barMinHeight + (Self.barMaxHeight - Self.barMinHeight) * (loud * 0.75 + wave * (0.25 + loud * 0.15))
                barHeights[i] = barHeights[i] * 0.5 + target * 0.5
            }
        case .processing:
            for i in 0..<Self.barCount {
                let wave = (sin(t * 3.5 + Double(i) * 0.75) + 1) / 2
                let target = Self.barMinHeight + (Self.barMaxHeight - Self.barMinHeight) * wave * 0.55
                barHeights[i] = barHeights[i] * 0.6 + target * 0.4
            }
        case .pasteFailed, .hint, .clipboardNotKept:
            barHeights = [Double](repeating: Self.barMinHeight, count: Self.barCount)
        }
        surface.setBarHeights(barHeights, color: PillAppearance(state: state, text: "").color)
    }

    /// The tick's three points in a 46 x 24 box: the short stroke draws first, then the long
    /// rising one. Ported from overlay_feedback.py.
    public static func checkmarkPoints(_ progress: Double) -> [Double] {
        let p = max(0, min(progress, 1))
        let short = min(p * 3, 1)
        let long = max(0, (p * 3 - 1) / 2)
        let elbow = 12 + 8 * short
        let tip = long > 0 ? [20 + 16 * long, 20 - 16 * long] : [elbow, elbow]
        return [12, 12, elbow, elbow] + tip
    }
}
