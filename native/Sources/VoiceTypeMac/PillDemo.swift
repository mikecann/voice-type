import AppKit
import QuartzCore
import VoiceTypeCore

/// Plays a scripted dictation in the real pill, for recording a clip of a change to it
/// without dictating: `voice-type-native pill-demo [LOOPS]`. It shows the pill on this Mac's
/// screen and touches nothing else (no microphone, keyboard tap or pasteboard).
public enum PillDemo {
    static let loopSeconds = 7.4
    static let keyDown = 0.5, keyUp = 4.0, pasted = 4.9
    static let final = "Move it to Thursday and send the notes."
    static let previews: [(Double, String)] = [(1.2, "Move it"), (1.9, "Move it to Thursday"), (2.8, "Move it to Thursday and send"), (3.5, final)]

    /// A made-up microphone RMS: syllable-sized bumps while talking, near silence either side.
    static func level(_ t: Double) -> Double {
        guard t > keyDown + 0.35 && t < keyUp - 0.15 else { return 0.003 }
        let syllable = abs(sin(t * 8.7)) * (0.55 + 0.45 * abs(sin(t * 2.1 + 1)))
        let pause = t > 2.35 && t < 2.55 ? 0.15 : 1
        return (0.12 + 0.88 * syllable * pause) / 14
    }

    public static func run(loops: Int) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let started = CACurrentMediaTime()
        let pill = MainThreadPill(level: { level((CACurrentMediaTime() - started).truncatingRemainder(dividingBy: loopSeconds)) })
        for loop in 0..<max(1, loops) {
            let base = Double(loop) * loopSeconds
            func at(_ t: Double, _ work: @escaping () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + base + t, execute: work)
            }
            at(keyDown) { pill.showRecording("") }
            for (t, text) in previews { at(t) { pill.showRecording(text) } }
            at(keyUp) { pill.showProcessing(final) }
            at(pasted) { pill.showDone(text: final) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(max(1, loops)) * loopSeconds) { exit(0) }
        app.run()
        exit(0)
    }
}
