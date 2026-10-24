import Foundation

// Pasting dictated text, ported from inject_text and _paste_via_pasteboard in platform_mac.py.
//
// The text goes on the clipboard and Voice Type presses Cmd+V. Every item and type already on
// the clipboard is copied out first (as bytes, since lazy providers may be gone after
// clearContents) and put back afterwards, so images, files and an empty clipboard survive.
//
// The text is offered lazily so we know when the target actually reads it. A busy app can
// take longer than any fixed delay, and restoring the old clipboard before it reads would
// paste the wrong thing. If nothing reads it within 2 s the paste didn't land, so the text
// stays on the clipboard for a manual Cmd+V. A read alone isn't proof either: Chromium apps
// (Claude, ChatGPT, Slack) read the clipboard on Cmd+V even with nothing editable focused, so
// once it's read, Accessibility is asked what has focus. If it isn't a text box (after half a
// second for apps that move a stray paste into one), the text stays on the clipboard too.
// Either way, anything copied in the meantime is never overwritten.
//
// macOS 26 can refuse the copy-out ("Paste from other apps" set to Deny, or Don't Allow
// clicked on its prompt). Then the snapshot is known to be missing things, and putting it
// back would wipe the clipboard, so it's never put back: the dictated text stays on the
// clipboard instead. The text has to go on the clipboard to be pasted at all, so whatever was
// there before is lost either way; leaving the words there is the least bad of the two, and
// the pill says once how to allow it.

/// One clipboard item: each type it had and its bytes.
public typealias PasteboardItemSnapshot = [(type: String, data: Data)]

/// The clipboard as it was before the paste, and whether it can be put back as it was.
public struct PasteboardSnapshot {
    public enum Readability: String, Equatable, Sendable {
        /// Everything that could be read was read, so putting it back loses nothing that matters.
        case complete
        /// macOS refused the read: "Paste from other apps" is denied for this app.
        case denied
        /// Something came back unreadable (or nothing came back while macOS might be hiding
        /// it), so putting it back could lose what the user copied.
        case incomplete
    }

    public var items: [PasteboardItemSnapshot]
    public var readability: Readability

    public init(items: [PasteboardItemSnapshot], readability: Readability = .complete) {
        self.items = items
        self.readability = readability
    }

    /// Decides what a copy-out is worth, from what was there and what could be read.
    ///
    /// - `typesPerItem`: how many types each item said it had; `items` holds the ones read.
    /// - `typesOnBoard`: the pasteboard's own type list, which macOS shows even when it hides
    ///   the data.
    /// - `access`: NSPasteboard.accessBehavior as GeneralPasteboard names it.
    ///
    /// An item missing some of its types still counts as complete, as in Python: a lazy
    /// provider that has gone away loses that one representation, and the rest still comes
    /// back. An item with types but no data at all doesn't.
    public static func classify(items: [PasteboardItemSnapshot], typesPerItem: [Int], typesOnBoard: Int, access: String) -> Readability {
        if access == "always_deny" { return .denied }
        let anyTypes = typesOnBoard > 0 || typesPerItem.contains { $0 > 0 }
        let anyData = items.contains { !$0.isEmpty }
        if anyTypes && !anyData { return .denied }
        if zip(items, typesPerItem).contains(where: { $0.isEmpty && $1 > 0 }) { return .incomplete }
        // An empty clipboard is only taken at its word when the read is always allowed; in
        // ask mode it may be macOS hiding it, and leaving the text there instead costs nothing.
        if !anyTypes && access != "always_allow" { return .incomplete }
        return .complete
    }
}

/// The general pasteboard, as the paste needs it.
public protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    /// Every item and type, materialised as bytes, and whether macOS let all of it be read.
    func snapshot() -> PasteboardSnapshot
    /// clearContents, then writes the saved items back (nothing, for an empty clipboard).
    func restore(_ items: [PasteboardItemSnapshot])
    /// clearContents, then one item that hands over `text` only when someone asks for it,
    /// calling `onRead` once it has. False if the pasteboard refused it.
    func offerLazily(_ text: String, onRead: @escaping @Sendable () -> Void) -> Bool
    /// clearContents, then `text` as a plain string, so a manual Cmd+V (or a late read) works.
    func placeText(_ text: String)
}

public enum FocusKind: String, Sendable {
    case editable, notEditable = "not-editable", unknown
}

public struct FocusReading: Equatable, Sendable {
    public var kind: FocusKind
    public var role: String?

    public init(_ kind: FocusKind, role: String? = nil) {
        self.kind = kind
        self.role = role
    }

    /// Text roles, or anything whose value can be set, take a paste.
    public static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    public static func classify(role: String?, valueSettable: Bool) -> FocusKind {
        guard let role, !role.isEmpty else { return .unknown }
        return editableRoles.contains(role) || valueSettable ? .editable : .notEditable
    }
}

/// The app that was in front at key-down.
public struct TargetApp: Equatable, Sendable {
    public var pid: Int32
    public var name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Everything the paste does to the rest of the system apart from the clipboard.
public protocol PasteEnvironment: AnyObject {
    func postCommandV()
    func frontmostPID() -> Int32?
    /// What has keyboard focus in app `pid`. Each Accessibility call has a 0.25 s limit, so
    /// a busy app can't stall pasting.
    func focus(inApp pid: Int32?) -> FocusReading
    /// Brings `app` to the front. False if it couldn't.
    func activate(_ app: TargetApp) -> Bool
    func playFailureSound()
}

public struct PasteError: LocalizedError {
    public var errorDescription: String? { "Could not put the transcription on the pasteboard" }
}

public struct PasteOutcome: Equatable, Sendable {
    public var landed: Bool
    /// How long the target took to read the text, nil if it never did.
    public var readLatency: Double?
    public var focusRole: String?
    public var refocused: Bool
    /// Whether the old clipboard could be read. Anything but complete means it wasn't put
    /// back, and the dictated text was left there instead.
    public var clipboard: PasteboardSnapshot.Readability = .complete
}

public final class Paster: @unchecked Sendable {
    public static let readTimeout = 2.0
    public static let textBoxWait = 0.5
    public static let focusPoll = 0.025
    public static let refocusSettle = 0.15
    public static let providerHandOver = 0.05

    private let pasteboard: Pasteboard
    private let environment: PasteEnvironment
    private let now: () -> Double
    private let sleep: (Double) -> Void
    private let log: (String) -> Void
    private let readTimeout: Double
    // Clipboard save, copy, paste and restore are one transaction; two must never interleave.
    private let transaction = NSLock()

    public init(pasteboard: Pasteboard, environment: PasteEnvironment, now: @escaping () -> Double, sleep: @escaping (Double) -> Void,
                log: @escaping (String) -> Void, readTimeout: Double = Paster.readTimeout) {
        self.pasteboard = pasteboard
        self.environment = environment
        self.now = now
        self.sleep = sleep
        self.log = log
        self.readTimeout = readTimeout
    }

    /// Pastes `text` into the app that was in front at key-down. Blocks until the target has
    /// read it (or 2 s pass), so never call it on the main thread: the read is answered there.
    public func paste(_ text: String, into target: TargetApp?) throws -> PasteOutcome {
        try transaction.withLock {
            sleep(0.05)
            let outcome = try pasteLocked(text, into: target)
            sleep(0.05)
            return outcome
        }
    }

    private func pasteLocked(_ text: String, into target: TargetApp?) throws -> PasteOutcome {
        // Something else may have come to the front while the key was held.
        let refocused = restoreFocus(target)
        if refocused { sleep(Self.refocusSettle) }
        var role: String?
        var readability = PasteboardSnapshot.Readability.complete
        let (latency, landed) = try pasteViaPasteboard(text, readability: &readability) {
            let (hasTextBox, focusRole) = self.waitForTextBox(pid: self.environment.frontmostPID())
            role = focusRole
            return hasTextBox
        }
        let outcome = PasteOutcome(landed: landed, readLatency: latency, focusRole: role, refocused: refocused, clipboard: readability)
        if !landed {
            environment.playFailureSound()
            if latency == nil {
                log(String(format: "Paste not confirmed: target never read the clipboard within %.1fs. Text left on the clipboard (%d chars).", readTimeout, text.count))
            } else {
                log("Paste went nowhere: the target read the clipboard but no text box had focus (\(role ?? "None")). Text left on the clipboard (\(text.count) chars).")
            }
        } else {
            log(String(format: "NSPasteboard+Cmd+V: %d chars injected (target read clipboard after %.0fms, focus %@%@)",
                       text.count, (latency ?? 0) * 1000, role ?? "unknown", refocused ? ", refocused target" : ""))
        }
        return outcome
    }

    /// Re-activates the key-down app only if another one is in front: the pill never takes
    /// focus, so it's usually still there, and re-activating cost 150 ms on every dictation.
    func restoreFocus(_ target: TargetApp?) -> Bool {
        guard let target else { return false }
        if environment.frontmostPID() == target.pid { return false }
        return environment.activate(target)
    }

    /// Returns the seconds the target took to read the text (nil if it never did) and
    /// whether the paste landed. If it didn't, the text is left on the clipboard.
    func pasteViaPasteboard(_ text: String, readability: inout PasteboardSnapshot.Readability, landed: () -> Bool) throws -> (Double?, Bool) {
        let snapshotStarted = now()
        // Read before anything on the clipboard changes, so a refused read is known in time.
        let saved = pasteboard.snapshot()
        readability = saved.readability
        let snapshotTook = now() - snapshotStarted
        if snapshotTook > 0.25 {
            // On macOS 26 the first programmatic read can wait on a "paste from other apps"
            // alert, which this makes visible in the log.
            log(String(format: "Reading the clipboard took %.2fs.", snapshotTook))
        }
        switch saved.readability {
        case .complete: break
        case .denied:
            log("macOS didn't let Voice Type Native read the clipboard (Paste from other apps is denied), so it can't be put back after this paste; the dictated text stays on it.")
        case .incomplete:
            log("The clipboard couldn't be read in full (or came back empty while macOS may be hiding it), so it won't be put back after this paste; the dictated text stays on it.")
        }
        let read = DispatchSemaphore(value: 0)
        guard pasteboard.offerLazily(text, onRead: { read.signal() }) else { throw PasteError() }
        let offered = pasteboard.changeCount
        let started = now()
        environment.postCommandV()
        guard read.wait(timeout: .now() + readTimeout) == .success else {
            leaveOnClipboard(text, offered: offered)
            return (nil, false)
        }
        let latency = now() - started
        // The provider hands the data over when its callback returns.
        sleep(Self.providerHandOver)
        guard landed() else {
            leaveOnClipboard(text, offered: offered)
            return (latency, false)
        }
        if pasteboard.changeCount == offered {
            // Never put back a copy known to be missing things: that would wipe the clipboard.
            if saved.readability == .complete { pasteboard.restore(saved.items) } else { pasteboard.placeText(text) }
        }
        return (latency, true)
    }

    private func leaveOnClipboard(_ text: String, offered: Int) {
        // Leave anything copied since the paste alone.
        if pasteboard.changeCount == offered { pasteboard.placeText(text) }
    }

    /// Whether a text box has focus now the target has read the paste. Focus on something
    /// that isn't editable gets half a second to move into one; when Accessibility can't
    /// tell, the paste is trusted.
    func waitForTextBox(pid: Int32?, wait: Double = Paster.textBoxWait, poll: Double = Paster.focusPoll) -> (Bool, String?) {
        let deadline = now() + wait
        while true {
            let reading = environment.focus(inApp: pid)
            if reading.kind != .notEditable || now() >= deadline {
                return (reading.kind != .notEditable, reading.role)
            }
            sleep(poll)
        }
    }
}
