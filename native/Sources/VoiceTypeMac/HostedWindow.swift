import AppKit
import SwiftUI

/// A SwiftUI view in an ordinary window, built when it's first shown and let go when it's
/// closed, so the settings and history windows cost nothing while they're shut. Main thread.
final class HostedWindow: NSObject, NSWindowDelegate {
    private let title: String
    private let size: NSSize
    private let minSize: NSSize
    private let autosaveName: String
    private let makeView: () -> AnyView
    private(set) var window: NSWindow?
    var onClose: () -> Void = {}

    init(title: String, size: NSSize, minSize: NSSize, autosaveName: String, makeView: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.autosaveName = autosaveName
        self.makeView = makeView
    }

    var isOpen: Bool { window != nil }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = title
            window.contentMinSize = minSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: makeView())
            window.setContentSize(size)
            // Remembers where it was put, and opens in the middle the first time.
            if !window.setFrameUsingName(autosaveName) { window.center() }
            window.setFrameAutosaveName(autosaveName)
            self.window = window
        }
        // A menu bar app isn't active by itself, and its window wouldn't take typing until it is.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose()
        // Dropping the hosting controller frees the SwiftUI view and everything it loaded.
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }
}

/// A small ⓘ that shows an explanation when clicked, so the windows only need short labels.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}
