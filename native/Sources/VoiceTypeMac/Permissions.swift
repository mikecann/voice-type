import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import VoiceTypeCore

/// The grants Voice Type Native needs. They belong to its bundle id and signing certificate,
/// so a rebuild signed the same way keeps them.
enum Permission: String, CaseIterable {
    case accessibility
    case inputMonitoring = "input_monitoring"
    case microphone
    case pasteFromOtherApps = "paste_from_other_apps"
    case screenRecording = "screen_recording"

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .microphone: return "Microphone"
        case .pasteFromOtherApps: return "Paste from other apps"
        case .screenRecording: return "Screen Recording"
        }
    }

    var why: String {
        switch self {
        case .accessibility: return "Holds F12 and Right Control for push-to-talk, presses Cmd+V and checks a text box has focus."
        case .inputMonitoring: return "Sees F12 and Right Control while another app is in front."
        case .microphone: return "Hears you while the key is down."
        case .pasteFromOtherApps: return "Copies what's on your clipboard before pasting, so it can put it back."
        case .screenRecording: return "Screenshots the window you draw on while holding the key. Asked the first time you draw."
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
        case .screenRecording: anchor = "?Privacy_ScreenCapture"
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
        case .screenRecording:
            // macOS only says yes or not yet; a refusal looks the same as never asked.
            return MacScreen.captureAllowed ? "allowed" : "denied"
        }
    }

    /// Dictation can't start without these. The clipboard one only matters for putting the
    /// clipboard back, and Screen Recording only for drawing, which asks for it itself.
    var isRequired: Bool {
        switch self {
        case .pasteFromOtherApps, .screenRecording: return false
        default: return true
        }
    }

    var isSatisfied: Bool { isSatisfied(state) }

    func isSatisfied(_ state: String) -> Bool {
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
        case .screenRecording:
            // The first time, this shows macOS's prompt and adds the app to the list.
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(settingsURL)
    }

    static var summary: [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.state) })
    }

    static var missing: [Permission] { allCases.filter { !$0.isSatisfied } }
}
