import AppKit
import VoiceTypeCore

/// The menu bar item: what Voice Type is doing, the microphone, permissions, the log, the
/// switch back to Python, and Quit. Main thread only.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var chooseMicrophone: (String) -> Void
        var setEnabled: (Bool) -> Void
        var showPermissions: () -> Void
        var openLog: () -> Void
        var switchToPython: () -> Void
        var switchToNative: () -> Void
        var tryAgain: () -> Void
        var quit: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let actions: Actions
    private let catalog: AudioDeviceCatalog
    private var status = NativeStatus(pid: getpid(), state: "starting")

    init(actions: Actions, catalog: AudioDeviceCatalog) {
        self.actions = actions
        self.catalog = catalog
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        update(status)
    }

    func update(_ status: NativeStatus) {
        self.status = status
        let symbol: String
        switch status.state {
        case "recording": symbol = "mic.fill"
        case "finalising": symbol = "ellipsis.circle"
        case "idle": symbol = status.enabled ? "mic" : "mic.slash"
        case "waiting_for_python": symbol = "mic.slash"
        case "waiting_for_permission", "needs_model", "needs_attention": symbol = "exclamationmark.triangle"
        default: symbol = "hourglass"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Type Native: \(Self.describe(status))")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Voice Type Native: \(Self.describe(status))"
    }

    static func describe(_ status: NativeStatus) -> String {
        switch status.state {
        case "idle": return status.enabled ? "Ready" : "Paused"
        case "recording": return "Recording"
        case "finalising": return "Transcribing"
        case "waiting_for_python": return "Python Voice Type is running"
        case "waiting_for_permission": return "Needs Accessibility and Input Monitoring"
        case "needs_model": return "Speech model missing"
        case "stopping": return "Stopping"
        case "retrying": return "Restarted after problems; trying again soon"
        case "needs_attention": return "Stopped after repeated problems"
        default: return status.message.isEmpty ? "Starting" : status.message.replacingOccurrences(of: "\n", with: " ")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: Self.describe(status), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if ["retrying", "needs_attention"].contains(status.state) && !status.message.isEmpty {
            // What went wrong, and that F12 and Right Control work as normal keys meanwhile.
            for line in [status.message, "F12 and Right Control work as normal keys until then."] {
                let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
            let retry = NSMenuItem(title: "Try Again", action: #selector(tryAgain), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        if let last = status.lastDictation {
            let note = last.landed == false ? ", left on the clipboard" : ""
            let info = NSMenuItem(title: "Last: \(last.words) word\(last.words == 1 ? "" : "s") (\(last.status))\(note)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())

        let waitingForPython = status.state == "waiting_for_python"
        if !waitingForPython {
            let microphones = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let chosen = status.preferredMicrophone
            var names = [""] + catalog.inputDevices().map(\.name)
            if !chosen.isEmpty && !names.contains(where: { $0.caseInsensitiveCompare(chosen) == .orderedSame }) { names.append(chosen) }
            var seen = Set<String>()
            for name in names where seen.insert(name.lowercased()).inserted {
                let live = name.isEmpty || catalog.inputDevices().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                let title = name.isEmpty ? "System Default" : live ? name : "\(name) (unavailable)"
                let entry = NSMenuItem(title: title, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = name
                entry.state = name.caseInsensitiveCompare(chosen) == .orderedSame ? .on : .off
                submenu.addItem(entry)
            }
            microphones.submenu = submenu
            menu.addItem(microphones)

            let enabled = NSMenuItem(title: "Dictation On", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
            enabled.target = self
            enabled.state = status.enabled ? .on : .off
            menu.addItem(enabled)
        }

        let missing = Permission.missing
        let permissions = NSMenuItem(title: missing.isEmpty ? "Permissions..." : "Permissions (\(missing.count) missing)...",
                                     action: #selector(showPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())

        let switcher = waitingForPython
            ? NSMenuItem(title: "Switch to Voice Type Native", action: #selector(switchToNative), keyEquivalent: "")
            : NSMenuItem(title: "Switch to Python Voice Type", action: #selector(switchToPython), keyEquivalent: "")
        switcher.target = self
        switcher.isEnabled = status.state != "stopping"
        menu.addItem(switcher)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voice Type Native", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) { actions.chooseMicrophone(sender.representedObject as? String ?? "") }
    @objc private func toggleEnabled(_ sender: NSMenuItem) { actions.setEnabled(sender.state != .on) }
    @objc private func showPermissions() { actions.showPermissions() }
    @objc private func openLog() { actions.openLog() }
    @objc private func switchToPython() { actions.switchToPython() }
    @objc private func switchToNative() { actions.switchToNative() }
    @objc private func tryAgain() { actions.tryAgain() }
    @objc private func quit() { actions.quit() }
}
