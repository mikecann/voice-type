import Foundation

/// What the pill at the bottom of the screen says, and when. The drawing lives in the app
/// (PillPanel.swift, a SwiftUI capsule that grows on a spring as the words come in); this
/// decides what to draw and for how long, so the timings can be tested.
///
/// REC is a red dot that pulses with your voice, white bars and the live words. While Whisper
/// runs the dot goes grey, the bars settle into rippling dots and a light passes along the
/// words. A paste that landed shows a green tick and what was typed for 0.8 s, then just the
/// tick for 0.3 s, then the pill drops away. A paste that didn't land says "On your clipboard.
/// ⌘V to paste" for 1.6 s or, when focus wasn't on a text box, what had it and what to do,
/// for 3 s so there's time to read it. A paste that landed when macOS wouldn't let the old
/// clipboard be read says so once, for 4 s.
public enum PillState: String, Sendable {
    case rec
    case processing
    case done
    case pasteFailed = "paste_failed"
    /// Pasted, but the old clipboard couldn't be read, so it's gone.
    case clipboardNotKept = "clipboard_not_kept"
    /// A dictation cut off by a crash was transcribed after the restart.
    case recovered
}

/// The mark at the start of the pill.
public enum PillMark: Sendable, Equatable {
    case red, grey, orange, green
    /// The green tick of a paste that landed.
    case tick
}

public struct PillAppearance: Equatable, Sendable {
    public var state: PillState
    /// The words beside the bars: the live preview, the text that was typed, or a notice.
    public var text: String
    /// Shown in front of the words for the last seconds before the 120 s cap.
    public var secondsLeft: Int?

    public init(state: PillState, text: String, secondsLeft: Int? = nil) {
        self.state = state
        self.text = text
        self.secondsLeft = state == .rec ? secondsLeft : nil
    }

    public var mark: PillMark {
        switch state {
        case .rec: return .red
        case .processing: return .grey
        case .done: return .tick
        case .pasteFailed, .clipboardNotKept: return .orange
        case .recovered: return .green
        }
    }

    /// The level bars show while it's listening or transcribing, not for feedback.
    public var showsBars: Bool { state == .rec || state == .processing }
    /// A light passes along the words while Whisper works on them.
    public var shimmers: Bool { state == .processing }
    /// Notices can run to two lines; dictated words stay on one, showing the newest.
    public var wraps: Bool { state.isNotice }
}

extension PillState {
    /// Feedback that isn't a dictation's own words.
    var isNotice: Bool { self == .pasteFailed || self == .clipboardNotKept || self == .recovered }
}

/// The parts of the pill that touch AppKit. Called on the main thread only.
public protocol PillSurface: AnyObject {
    /// Shows the pill, or changes what it shows if it's already up. The surface animates
    /// between appearances itself.
    func present(_ appearance: PillAppearance)
    /// Sends the pill away (animated, unless Reduce Motion is on). A `present` while it's
    /// leaving brings it straight back.
    func hide()
    /// One frame of the bars: each one's height in points and opacity, and how loud the
    /// microphone is (0...1), which the red dot pulses with.
    func setBars(heights: [Double], opacities: [Double], level: Double)
}

public protocol Cancellable: AnyObject { func cancel() }

/// Runs work later on the pill's thread (the main thread in the app).
public protocol Scheduler: AnyObject {
    @discardableResult func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable
}

public final class PillController {
    public static let barCount = 9
    public static let barMinHeight = 3.0
    public static let barMaxHeight = 18.0
    /// How long the typed text shows beside the tick.
    public static let doneHoldSeconds = 0.8
    /// Then just the tick, before the pill drops away.
    public static let tickHoldSeconds = 0.3
    public static let failureHoldSeconds = 1.6
    /// The focus miss says more than "On your clipboard", so it stays up longer.
    public static let focusMissHoldSeconds = 3.0
    public static let clipboardNoticeHoldSeconds = 4.0

    private let surface: PillSurface
    private let scheduler: Scheduler

    public private(set) var state: PillState?
    public private(set) var isVisible = false
    /// The cap's countdown while it runs; REC shows again for the next recording.
    private var secondsLeft: Int?
    private var lastText = ""
    private var feedbackTimer: Cancellable?
    public private(set) var barHeights = [Double](repeating: barMinHeight, count: barCount)

    public init(surface: PillSurface, scheduler: Scheduler) {
        self.surface = surface
        self.scheduler = scheduler
    }

    public func showRecording(_ preview: String = "") { show(.rec, preview) }

    /// The last seconds before the 120 s cap stops the recording, in front of the words, so
    /// it doesn't stop mid-sentence without warning.
    public func showSecondsLeft(_ seconds: Int) {
        guard state == .rec else { return }
        secondsLeft = seconds
        surface.present(PillAppearance(state: .rec, text: lastText, secondsLeft: seconds))
    }

    public func showProcessing(_ preview: String = "") { show(.processing, preview) }

    /// `text` is what was typed, shown beside the tick.
    public func showDone(text: String) { show(.done, text) }

    /// With `miss`, says what had focus instead of a text box, in the log's words.
    public func showPasteFailed(_ miss: FocusMiss? = nil) {
        if let miss {
            show(.pasteFailed, miss.pillMessage, hold: Self.focusMissHoldSeconds)
        } else {
            show(.pasteFailed, "On your clipboard. \u{2318}V to paste")
        }
    }

    public func showClipboardNotKept() { show(.clipboardNotKept, "Allow Paste from other apps to keep your clipboard") }

    /// "A 68 s dictation is in History", for 4 s like the clipboard notice.
    public func showRecovered(count: Int, seconds: Double) {
        let text = count == 1 ? "A \(Int(seconds.rounded())) s dictation is in History" : "\(count) dictations are in History"
        show(.recovered, text, hold: Self.clipboardNoticeHoldSeconds)
    }

    public func hide() {
        cancelFeedback()
        if isVisible { surface.hide() }
        isVisible = false
        state = nil
        secondsLeft = nil
    }

    private func show(_ newState: PillState, _ text: String, hold holdOverride: Double? = nil) {
        cancelFeedback()
        if newState != .rec { secondsLeft = nil }
        state = newState
        lastText = text
        if !newState.isNotice && newState != .done && !isVisible {
            barHeights = [Double](repeating: Self.barMinHeight, count: Self.barCount)
        }
        surface.present(PillAppearance(state: newState, text: text, secondsLeft: newState == .rec ? secondsLeft : nil))
        isVisible = true
        switch newState {
        case .done:
            feedbackTimer = scheduler.schedule(after: Self.doneHoldSeconds) { [weak self] in self?.collapseToTick() }
        case .pasteFailed, .clipboardNotKept, .recovered:
            let hold = holdOverride ?? (newState == .clipboardNotKept ? Self.clipboardNoticeHoldSeconds : Self.failureHoldSeconds)
            feedbackTimer = scheduler.schedule(after: hold) { [weak self] in self?.hide() }
        case .rec, .processing:
            break
        }
    }

    /// The words go and the pill shrinks to the tick, which then drops away.
    private func collapseToTick() {
        guard state == .done else { return }
        lastText = ""
        surface.present(PillAppearance(state: .done, text: ""))
        feedbackTimer = scheduler.schedule(after: Self.tickHoldSeconds) { [weak self] in self?.hide() }
    }

    private func cancelFeedback() {
        feedbackTimer?.cancel()
        feedbackTimer = nil
    }

    /// One animation frame, about 60 a second while the pill shows. `level` is the RMS of the
    /// last bit of audio, which drives the bars and the dot.
    public func animationFrame(level: Double, time t: Double) {
        guard isVisible, let state else { return }
        // A typical microphone RMS is 0.01 to 0.07.
        let loud = min(level * 14, 1)
        var opacities = [Double](repeating: 1, count: Self.barCount)
        switch state {
        case .rec:
            let middle = Double(Self.barCount - 1) / 2
            for i in 0..<Self.barCount {
                // Taller in the middle, each bar wobbling at its own speed, so it reads as a
                // voice rather than a meter.
                let wave = (sin(t * (6 + Double(i) * 0.7) + Double(i)) + 1) / 2
                let taper = 1 - abs(Double(i) - middle) / (middle + 3)
                let target = Self.barMinHeight + (Self.barMaxHeight - Self.barMinHeight) * taper * min(1, loud * (0.55 + 0.45 * wave) + 0.06 * wave)
                barHeights[i] = barHeights[i] * 0.55 + target * 0.45
            }
        case .processing:
            for i in 0..<Self.barCount {
                barHeights[i] = barHeights[i] * 0.75 + Self.barMinHeight * 0.25
                opacities[i] = 0.35 + 0.65 * max(0, sin(t * 9 - Double(i) * 0.7))
            }
        case .done, .pasteFailed, .clipboardNotKept, .recovered:
            return
        }
        surface.setBars(heights: barHeights, opacities: opacities, level: state == .rec ? loud : 0)
    }
}
