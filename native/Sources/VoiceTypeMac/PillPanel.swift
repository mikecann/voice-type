import AppKit
import QuartzCore
import SwiftUI
import VoiceTypeCore

// The pill at the bottom of the screen: a borderless, see-through panel that never takes
// focus or clicks, on every Space and over full-screen apps, holding a SwiftUI capsule that
// grows and shrinks on a spring as its contents change. What it says and when is
// PillController's job in VoiceTypeCore; this only draws.

private enum PillLayout {
    /// The panel is fixed and bigger than the capsule will ever be, so the capsule can
    /// change size and spring about inside it without the window being resized every frame.
    static let panelSize = NSSize(width: 760, height: 130)
    static let bottomMargin: CGFloat = 20
    static let minHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 20
    static let fontSize: CGFloat = 13.5
    /// Past this the oldest words drop off the front, so the newest always show.
    static let maxTextWidth: CGFloat = 520
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2.5
}

private enum PillColors {
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1, green: 0.62, blue: 0.04)
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let grey = Color(white: 0.56)
    static let fill = Color(white: 0.045)
}

/// What the capsule shows. Only touched on the main thread.
@Observable final class PillModel {
    var appearance = PillAppearance(state: .rec, text: "")
    var shown = false
    var heights = [Double](repeating: PillController.barMinHeight, count: PillController.barCount)
    var opacities = [Double](repeating: 1, count: PillController.barCount)
    var level = 0.0
    /// Drives the light passing along the words while Whisper runs.
    var time = 0.0
}

/// One word of the live text. Its id is its place in the whole text plus the word, so a word
/// Whisper revises animates in again, and words dropping off the front don't move the rest.
struct PillWord: Identifiable, Equatable {
    let id: String
    let text: String

    static let font = NSFont.systemFont(ofSize: PillLayout.fontSize)
    static var spaceWidth: CGFloat { width(" ") }

    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The last words of `text` that fit in `maxWidth`, after an ellipsis if any were cut.
    static func fitting(_ text: String, maxWidth: CGFloat = PillLayout.maxTextWidth) -> [PillWord] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [PillWord] = []
        var used: CGFloat = 0
        let ellipsis = width("\u{2026}") + spaceWidth
        for (index, word) in words.enumerated().reversed() {
            let needed = width(word) + (kept.isEmpty ? 0 : spaceWidth)
            let reserve = index > 0 ? ellipsis : 0
            if used + needed + reserve > maxWidth && !kept.isEmpty { break }
            used += needed
            kept.insert(PillWord(id: "\(index):\(word)", text: word), at: 0)
        }
        if kept.count < words.count { kept.insert(PillWord(id: "\u{2026}", text: "\u{2026}"), at: 0) }
        return kept
    }
}

private struct BlurIn: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.blur(radius: active ? 6 : 0).opacity(active ? 0 : 1).offset(y: active ? 5 : 0)
    }
}

private extension AnyTransition {
    /// New words arrive out of a blur, rising a little.
    static func blurIn(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .modifier(active: BlurIn(active: true), identity: BlurIn(active: false)), removal: .opacity)
    }
}

/// The tick's two strokes in an 18 point circle.
private struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.29, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.width * 0.43, y: rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.37))
        return path
    }
}

private struct TickMark: View {
    let reduceMotion: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        Circle().fill(PillColors.green)
            .overlay(TickShape().trim(from: 0, to: drawn)
                .stroke(Color(red: 0.02, green: 0.13, blue: 0.06), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)))
            .onAppear {
                // The circle pops in on the capsule's spring; the tick draws itself just after.
                if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 0.2).delay(0.08)) { drawn = 1 } }
            }
    }
}

private struct MarkView: View {
    let mark: PillMark
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if mark == .tick {
                TickMark(reduceMotion: reduceMotion)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
                    // The red dot breathes with your voice.
                    .scaleEffect(mark == .red ? 1 + level * 0.45 : mark == .grey ? 0.8 : 1)
                    .shadow(color: mark == .red ? PillColors.red.opacity(0.75) : .clear, radius: 3 + level * 5)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
    }

    private var color: Color {
        switch mark {
        case .red: return PillColors.red
        case .grey: return PillColors.grey
        case .orange: return PillColors.orange
        case .green, .tick: return PillColors.green
        }
    }
}

private struct BarsView: View {
    let heights: [Double]
    let opacities: [Double]

    var body: some View {
        HStack(spacing: PillLayout.barGap) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(.white)
                    .frame(width: PillLayout.barWidth, height: max(PillLayout.barWidth, heights[i]))
                    .opacity(opacities[i])
            }
        }
        .frame(height: 20)
    }
}

private struct WordsView: View {
    let words: [PillWord]
    let state: PillState
    let shimmerTime: Double?
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: PillWord.spaceWidth) {
            ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                Text(word.text)
                    .font(.system(size: PillLayout.fontSize))
                    .foregroundStyle(color(index))
                    .transition(.blurIn(reduceMotion: reduceMotion))
            }
        }
        .fixedSize()
    }

    private func color(_ index: Int) -> Color {
        if state == .done { return .white }
        guard let t = shimmerTime, !reduceMotion else { return Color(white: state == .processing ? 0.6 : 0.86) }
        // A light runs along the words every 1.1 s while Whisper works on them.
        let period = 1.1
        let phase = (t - Double(index) * 0.07).truncatingRemainder(dividingBy: period) / period
        let p = phase < 0 ? phase + 1 : phase
        let glow = p < 0.4 ? p / 0.4 : max(0, (0.75 - p) / 0.35)
        return Color(white: 0.45 + 0.55 * glow)
    }
}

struct PillView: View {
    let model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let a = model.appearance
        HStack(spacing: 10) {
            MarkView(mark: a.mark, level: model.level, reduceMotion: reduceMotion)
            if a.showsBars {
                BarsView(heights: model.heights, opacities: model.opacities)
                    // Gone quickly on the way out, so the words sliding left don't run over them.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.3, anchor: .leading)),
                                            removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
            if let seconds = a.secondsLeft {
                Text("\(seconds)s")
                    .font(.system(size: PillLayout.fontSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PillColors.red)
                    .contentTransition(.numericText(countsDown: true))
                    .transition(.opacity)
            }
            if !a.text.isEmpty {
                if a.wraps {
                    Text(a.text)
                        .font(.system(size: PillLayout.fontSize))
                        .foregroundStyle(Color(white: 0.92))
                        .lineLimit(2)
                        .frame(maxWidth: PillLayout.maxTextWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.blurIn(reduceMotion: reduceMotion))
                } else {
                    WordsView(words: PillWord.fitting(a.text), state: a.state, shimmerTime: a.shimmers ? model.time : nil,
                              reduceMotion: reduceMotion)
                }
            }
        }
        .padding(.leading, 11)
        // Just the mark (a pasted dictation's tick on its way out) makes a circle.
        .padding(.trailing, a.text.isEmpty && !a.showsBars && a.secondsLeft == nil ? 11 : 16)
        .padding(.vertical, 11)
        .frame(minHeight: PillLayout.minHeight)
        // Words on their way out stay inside the capsule as it shrinks.
        .clipShape(RoundedRectangle(cornerRadius: PillLayout.cornerRadius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: PillLayout.cornerRadius, style: .continuous)
                .fill(PillColors.fill)
                .overlay(RoundedRectangle(cornerRadius: PillLayout.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.68), value: a)
        // It bounces in from below and drops away on the way out.
        .scaleEffect(model.shown || reduceMotion ? 1 : 0.6, anchor: .bottom)
        .offset(y: model.shown || reduceMotion ? 0 : 26)
        .opacity(model.shown ? 1 : 0)
        .animation(model.shown ? .spring(response: 0.42, dampingFraction: 0.62) : .easeIn(duration: 0.2), value: model.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, PillLayout.bottomMargin)
        .allowsHitTesting(false)
    }
}

final class PillPanel: PillSurface {
    /// How long the exit animation gets before the panel is taken off screen.
    private static let exitSeconds = 0.3

    private let panel: NSPanel
    private let model = PillModel()
    private var orderOut: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: PillLayout.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow; a window shadow would outline the whole panel.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PillView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: PillLayout.panelSize)
        panel.contentView = host
    }

    func present(_ appearance: PillAppearance) {
        orderOut?.cancel()
        orderOut = nil
        if panel.isVisible {
            model.appearance = appearance
            model.shown = true
            return
        }
        // Start from the small, low, see-through pose with nothing animated, then spring up
        // from it once SwiftUI has drawn that pose.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.appearance = appearance
            model.shown = false
        }
        position()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [self] in
            guard orderOut == nil, panel.isVisible else { return }
            model.shown = true
        }
    }

    func hide() {
        model.shown = false
        orderOut?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.orderOut = nil
        }
        orderOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitSeconds, execute: work)
    }

    func setBars(heights: [Double], opacities: [Double], level: Double) {
        model.heights = heights
        model.opacities = opacities
        model.level = level
        model.time = CACurrentMediaTime()
    }

    /// Bottom centre of the main screen's visible area.
    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - PillLayout.panelSize.width / 2, y: visible.minY,
                              width: PillLayout.panelSize.width, height: PillLayout.panelSize.height), display: true)
    }
}

/// The pill for the controller, which calls from its own queue: everything hops to the
/// main thread. Also runs the bars at 60 fps while the pill shows.
final class MainThreadPill: PillPresenting, @unchecked Sendable {
    private var controller: PillController!
    private var timer: Timer?
    private let level: () -> Double

    init(level: @escaping () -> Double) {
        self.level = level
        DispatchQueue.main.async { [self] in
            controller = PillController(surface: PillPanel(), scheduler: QueueExecutor(.main))
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
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
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
    func showDone(text: String) { onMain { $0.showDone(text: text) } }
    func showPasteFailed(_ miss: FocusMiss?) { onMain { $0.showPasteFailed(miss) } }
    func showClipboardNotKept() { onMain { $0.showClipboardNotKept() } }
    func showRecovered(count: Int, seconds: Double) { onMain { $0.showRecovered(count: count, seconds: seconds) } }
    func hide() { onMain { $0.hide() } }
}
