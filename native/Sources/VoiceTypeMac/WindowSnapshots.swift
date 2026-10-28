import AppKit
import SwiftUI
import VoiceTypeCore

/// Saves PNGs of the settings and history windows, for checking a change to them (and for
/// the README) while the app keeps running and without taking focus.
/// `voice-type-native snapshot-windows DIR`; set VOICE_TYPE_DATA_DIR to use other data.
public enum WindowSnapshots {
    public static func render(to directory: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let actions = SettingsModel.Actions(setEnabled: { _ in }, chooseMicrophone: { _ in }, update: { _, _ in },
                                            openLog: {}, openDataFolder: {}, restart: {})
        let settings = SettingsModel(actions: actions, catalog: CoreAudioCatalog())
        var status = NativeStatus.read() ?? NativeStatus(pid: getpid(), state: "idle")
        status.enabled = true
        settings.reload(status: status)
        for (tab, name) in [(SettingsModel.Tab.general, "settings-general"), (.words, "settings-words"), (.permissions, "settings-permissions")] {
            settings.tab = tab
            try snapshot(AnyView(SettingsView(model: settings)), size: NSSize(width: 520, height: 500), to: directory.appendingPathComponent("\(name).png"))
        }

        let history = HistoryModel(actions: HistoryModel.Actions(
            load: { done in done(DictationHistory.load(recordings: VoiceTypePaths.recordingsDirectory, historyFile: VoiceTypePaths.historyFile)) },
            retranscribe: { _, done in done(nil) }, fix: { _, _, done in done(false) }
        ))
        history.reload()
        try snapshot(AnyView(HistoryView(model: history)), size: NSSize(width: 680, height: 560), to: directory.appendingPathComponent("history.png"))
    }

    /// Puts the view in a real window behind every other one, so it doesn't take focus or
    /// cover anything, lets SwiftUI and the thumbnails settle, then has screencapture grab just
    /// that window. (Drawing the view into a bitmap misses the tab bar and text fields, and
    /// screencapture can't read a window that's off every screen.)
    private static func snapshot(_ view: AnyView, size: NSSize, to url: URL) throws {
        let window = UnconstrainedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.order(.below, relativeTo: 0)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        window.close()
        guard capture.terminationStatus == 0 else { throw POSIXError(.EIO) }
    }
}

/// A window AppKit leaves where it's put.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
