/// Which push-to-talk keys are held, ported from MacPushToTalkHotkeys in platform_mac.py.
///
/// F12 and Right Control both work, and either one held counts as down. F12 comes through as
/// key-down and key-up. Right Control only ever arrives as a flags-changed event, which says
/// a modifier changed without saying whether it went up or down, so the device-dependent
/// right-control bit (0x2000) in the event's flags tells us. Left Control has keycode 0x3B
/// and is never touched, so it keeps working as Control everywhere.
///
/// Not thread-safe on its own: the event tap's thread is the only one that calls it.
public struct HotkeyState: Sendable {
    public static let f12: Int64 = 111
    public static let rightControl: Int64 = 0x3E
    /// NX_DEVICERCTLKEYMASK: the right Control key is down.
    public static let deviceRightControlMask: UInt64 = 0x0000_2000

    public enum EventKind: Sendable { case keyDown, keyUp, flagsChanged }

    /// What the tap does with an event.
    public enum Disposition: Sendable, Equatable {
        /// Not F12 or Right Control: the event goes on untouched.
        case notOurs
        /// Ours, and the system never sees it (as Python's tap did).
        case swallow
        /// Ours, and still tracked, but it goes on to the system too: Voice Type isn't
        /// taking dictation (paused, no model, or given up), so the keys keep their usual jobs.
        case passThrough
    }

    private var down: Set<Int64> = []
    /// Keys whose press went through to the system, so their release does too.
    private var passing: Set<Int64> = []

    public init() {}

    public var isDown: Bool { !down.isEmpty }

    /// Applies one keyboard event. Returns true when it was one of ours, in which case the
    /// tap swallows it so the rest of the system never sees it (as Python's tap did).
    public mutating func handle(_ kind: EventKind, keycode: Int64, flags: UInt64) -> Bool {
        handle(kind, keycode: keycode, flags: flags, swallowing: true) != .notOurs
    }

    /// Applies one keyboard event and says whether to swallow it. `swallowing` is decided at
    /// each key's press and kept until its release, so the system never sees a release
    /// without its press or the other way round. A release whose press this never saw (it
    /// was down before the tap started) goes through, since the system saw the press.
    public mutating func handle(_ kind: EventKind, keycode: Int64, flags: UInt64, swallowing: Bool) -> Disposition {
        let physicallyDown: Bool
        switch (keycode, kind) {
        case (Self.f12, .keyDown): physicallyDown = true
        case (Self.f12, .keyUp): physicallyDown = false
        case (Self.rightControl, .flagsChanged): physicallyDown = flags & Self.deviceRightControlMask != 0
        default: return .notOurs
        }
        let wasDown = down.contains(keycode)
        if physicallyDown {
            if !wasDown {
                if swallowing { passing.remove(keycode) } else { passing.insert(keycode) }
            }
            down.insert(keycode)
            return passing.contains(keycode) ? .passThrough : .swallow
        }
        down.remove(keycode)
        let passed = !wasDown || passing.contains(keycode)
        passing.remove(keycode)
        return passed ? .passThrough : .swallow
    }

    /// Forgets every key, after the tap missed events (a timeout, or sleep).
    public mutating func reset() {
        down.removeAll()
        passing.removeAll()
    }
}

public enum PreviewFormat {
    public static let maxChars = 32

    /// Word-wraps the live preview to its last two lines, with a leading ellipsis when
    /// earlier lines were cut. Ported from preview_format.py.
    public static func wrap(_ text: String, maxChars: Int = maxChars) -> String {
        guard !text.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        // len() in Python counts code points.
        for word in PythonText.split(text) {
            if !current.isEmpty && current.unicodeScalars.count + 1 + word.unicodeScalars.count > maxChars {
                lines.append(current)
                current = word
            } else {
                current = current.isEmpty ? word : current + " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        guard !lines.isEmpty else { return "" }
        let prefix = lines.count > 2 ? "\u{2026}" : ""
        return prefix + lines.suffix(2).joined(separator: "\n")
    }

    /// How the Python preview loop joins segments: each stripped, joined with spaces, then
    /// stripped again. Unlike the final text it keeps empty segments' spaces, and it skips the
    /// loop guard and corrections.
    public static func previewText(_ transcript: Transcript) -> String {
        PythonText.strip(transcript.segments.map { PythonText.strip($0.text) }.joined(separator: " "))
    }
}
