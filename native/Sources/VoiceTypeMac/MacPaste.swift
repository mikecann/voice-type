import AppKit
import ApplicationServices
import CoreGraphics
import VoiceTypeCore

/// NSPasteboard.general, as the paste flow in VoiceTypeCore needs it.
final class GeneralPasteboard: VoiceTypeCore.Pasteboard, @unchecked Sendable {
    private let board = NSPasteboard.general
    // The pasteboard only holds a weak reference to its data provider.
    private var liveProvider: TextProvider?
    private var liveDataProvider: DataProvider?

    var changeCount: Int { board.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let access = Self.accessBehavior
        // Denied outright: don't even try, since the read would only come back empty.
        if access == "always_deny" { return PasteboardSnapshot(items: [], readability: .denied) }
        let items = board.pasteboardItems ?? []
        let saved = items.map { item in
            item.types.compactMap { type in
                // Copied out now: lazy providers may be gone once the clipboard is cleared.
                item.data(forType: type).map { data in (type.rawValue, data.withUnsafeBytes { Data($0) }) }
            }
        }
        let readability = PasteboardSnapshot.classify(items: saved, typesPerItem: items.map(\.types.count),
                                                      typesOnBoard: board.types?.count ?? 0, access: access)
        return PasteboardSnapshot(items: saved, readability: readability)
    }

    func restore(_ items: [PasteboardItemSnapshot]) {
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
    }

    func offerLazily(_ text: String, onRead: @escaping @Sendable () -> Void) -> Bool {
        board.clearContents()
        let provider = TextProvider(text: text, onRead: onRead)
        liveProvider = provider
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        return board.writeObjects([item])
    }

    func placeText(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func offerLazily(data: Data, type: String, onRead: @escaping @Sendable () -> Void) -> Bool {
        board.clearContents()
        let provider = DataProvider(data: data, onRead: onRead)
        liveDataProvider = provider
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType(type)])
        return board.writeObjects([item])
    }

    func placeData(_ data: Data, type: String) {
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType(type))
    }

    /// macOS 26 can ask before an app reads the clipboard, and the snapshot above is such a
    /// read. This is what the user has chosen, for the status file and permissions window.
    static var accessBehavior: String {
        switch NSPasteboard.general.accessBehavior {
        case .default: return "default"
        case .ask: return "ask"
        case .alwaysAllow: return "always_allow"
        case .alwaysDeny: return "always_deny"
        @unknown default: return "unknown"
        }
    }
}

/// Hands the text over only when the target app asks for it, which is how we know the paste
/// was read. Called on the main thread's run loop, so nothing may wait for a read there.
final class TextProvider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    let onRead: @Sendable () -> Void

    init(text: String, onRead: @escaping @Sendable () -> Void) {
        self.text = text
        self.onRead = onRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        onRead()
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// TextProvider for a screenshot's bytes.
final class DataProvider: NSObject, NSPasteboardItemDataProvider {
    let data: Data
    let onRead: @Sendable () -> Void

    init(data: Data, onRead: @escaping @Sendable () -> Void) {
        self.data = data
        self.onRead = onRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(data, forType: type)
        onRead()
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

final class MacPasteEnvironment: PasteEnvironment, @unchecked Sendable {
    // macOS virtual keycodes: left Command and V (QWERTY).
    private static let command: CGKeyCode = 55
    private static let v: CGKeyCode = 9
    private static let accessibilityTimeout: Float = 0.25

    /// Cmd+V posted straight to the HID stream, which is thread-safe, unlike typing through
    /// the Text Services APIs (pynput's crash on a background thread).
    func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (Self.command, true, .maskCommand), (Self.v, true, .maskCommand), (Self.v, false, .maskCommand), (Self.command, false, []),
        ]
        for (key, down, flags) in events {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func frontmostApp() -> TargetApp? {
        NSWorkspace.shared.frontmostApplication.map { TargetApp(pid: $0.processIdentifier, name: $0.localizedName ?? "unknown") }
    }

    /// The paste waits on the finalise lane, never here, so the main thread is free to
    /// answer unless something else is holding it, which would also stop the lazy item
    /// from being handed over.
    func mainThreadLatency(timeout: Double) -> Double? {
        let answered = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.main.async { answered.signal() }
        guard answered.wait(timeout: started + timeout) == .success else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
    }

    func focus(inApp pid: Int32?) -> FocusReading {
        guard let pid else { return FocusReading(.unknown) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.accessibilityTimeout)
        var focused: CFTypeRef?
        // A Chromium app that isn't in front, or has just started, may report no focus at
        // all, which can't be told apart from a real miss.
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return FocusReading(.unknown) }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.accessibilityTimeout)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return FocusReading(.unknown) }
        let roleName = role as? String
        var settable: DarwinBoolean = false
        let settableOK = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        return FocusReading(FocusReading.classify(role: roleName, valueSettable: settableOK && settable.boolValue), role: roleName)
    }

    func activate(_ app: TargetApp) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        // NSApplicationActivateIgnoringOtherApps, as Python passed it. The named option is
        // deprecated, but it's what has worked from a background app.
        return running.activate(options: NSApplication.ActivationOptions(rawValue: 1 << 1))
    }

    func playFailureSound() {
        DispatchQueue.main.async {
            NSSound(contentsOfFile: "/System/Library/Sounds/Funk.aiff", byReference: true)?.play()
        }
    }
}
