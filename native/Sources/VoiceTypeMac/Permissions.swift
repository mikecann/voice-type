import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import VoiceTypeCore

/// The grants Voice Type Native needs. They belong to its own bundle id, so they're asked for
/// once even though Python's are already there, and Python's stay put for switching back.
enum Permission: String, CaseIterable {
    case accessibility
    case inputMonitoring = "input_monitoring"
    case microphone
    case pasteFromOtherApps = "paste_from_other_apps"

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .microphone: return "Microphone"
        case .pasteFromOtherApps: return "Paste from other apps"
        }
    }

    var why: String {
        switch self {
        case .accessibility: return "Holds F12 and Right Control for push-to-talk, presses Cmd+V and checks a text box has focus."
        case .inputMonitoring: return "Sees F12 and Right Control while another app is in front."
        case .microphone: return "Hears you while the key is down."
        case .pasteFromOtherApps: return "Copies what's on your clipboard before pasting, so it can put it back."
        }
    }

    /// Privacy & Security panes. The clipboard one has no documented anchor, so it opens the
    /// Privacy & Security list.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "?Privacy_Accessibility"
        case .inputMonitoring: anchor = "?Privacy_ListenEvent"
        case .microphone: anchor = "?Privacy_Microphone"
        case .pasteFromOtherApps: anchor = ""
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security\(anchor)")!
    }

    /// allowed, denied, not_asked, or (for the clipboard) ask.
    var state: String {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? "allowed" : "denied"
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? "allowed" : "denied"
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "allowed"
            case .notDetermined: return "not_asked"
            default: return "denied"
            }
        case .pasteFromOtherApps:
            switch GeneralPasteboard.accessBehavior {
            case "always_allow": return "allowed"
            case "always_deny": return "denied"
            case "ask": return "ask"
            default: return "not_asked"
            }
        }
    }

    var isSatisfied: Bool {
        switch self {
        // "Ask" works: macOS asks, and Allow lets the read through.
        case .pasteFromOtherApps: return state != "denied"
        default: return state == "allowed"
        }
    }

    /// Shows the system prompt where there is one, which also adds Voice Type Native to the
    /// list in System Settings, then opens the right pane.
    func request() {
        switch self {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return
            }
        case .pasteFromOtherApps:
            // A read of the general pasteboard is what makes macOS ask (and list the app), so
            // do one now, while someone's watching, rather than in the middle of a dictation.
            _ = NSPasteboard.general.pasteboardItems?.first?.types.first.flatMap { NSPasteboard.general.data(forType: $0) }
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }

    static var summary: [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.state) })
    }

    static var missing: [Permission] { allCases.filter { !$0.isSatisfied } }
}

/// A small window listing each permission with a button to grant it. It opens by itself at
/// launch when something's missing, and from the menu.
final class PermissionsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var rows: [(Permission, NSTextField, NSButton)] = []
    private var refresh: Timer?

    func show() {
        if window == nil { build() }
        update()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate()
        refresh = nil
    }

    private func build() {
        let width: CGFloat = 520
        let rowHeight: CGFloat = 64
        let height = CGFloat(Permission.allCases.count) * rowHeight + 70
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Voice Type Native permissions"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content

        let intro = NSTextField(wrappingLabelWithString: "Voice Type Native needs these before it can take over from the Python app. Python keeps its own, so switching back still works.")
        intro.frame = NSRect(x: 20, y: height - 50, width: width - 40, height: 34)
        content.addSubview(intro)

        for (i, permission) in Permission.allCases.enumerated() {
            let top = height - 70 - CGFloat(i + 1) * rowHeight + 8
            let title = NSTextField(labelWithString: permission.title)
            title.font = .boldSystemFont(ofSize: 13)
            title.frame = NSRect(x: 20, y: top + 32, width: 200, height: 18)
            let why = NSTextField(wrappingLabelWithString: permission.why)
            why.font = .systemFont(ofSize: 11)
            why.textColor = .secondaryLabelColor
            why.frame = NSRect(x: 20, y: top, width: 300, height: 30)
            let state = NSTextField(labelWithString: "")
            state.frame = NSRect(x: 330, y: top + 32, width: 170, height: 18)
            let button = NSButton(title: "Open System Settings", target: self, action: #selector(grant(_:)))
            button.tag = i
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 326, y: top + 2, width: 180, height: 28)
            for view in [title, why, state, button] { content.addSubview(view) }
            rows.append((permission, state, button))
        }
        window.center()
        self.window = window
    }

    private func update() {
        for (permission, state, button) in rows {
            let value = permission.state
            switch value {
            case "allowed": state.stringValue = "Allowed"
            case "ask": state.stringValue = "Asks each time"
            case "not_asked": state.stringValue = "Not asked yet"
            default: state.stringValue = "Not allowed"
            }
            state.textColor = permission.isSatisfied ? .systemGreen : .systemOrange
            if permission == .pasteFromOtherApps {
                button.title = value == "not_asked" ? "Check now" : "Open System Settings"
            } else if permission == .microphone && value == "not_asked" {
                button.title = "Ask now"
            } else {
                button.title = "Open System Settings"
            }
            button.isEnabled = !(permission.state == "allowed")
        }
    }

    @objc private func grant(_ sender: NSButton) {
        let permission = Permission.allCases[sender.tag]
        if permission == .pasteFromOtherApps && permission.state != "not_asked" {
            NSWorkspace.shared.open(permission.settingsURL)
        } else {
            permission.request()
        }
        update()
    }
}
