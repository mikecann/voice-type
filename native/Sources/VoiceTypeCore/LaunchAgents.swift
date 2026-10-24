import Foundation

// Voice Type Native runs from its own LaunchAgent, so launchd starts it at login and brings it
// back after a crash or a watchdog's exit 75. The instance lock stops a second copy (one
// opened by hand, say) from dictating at the same time.

public enum LaunchAgents {
    public static let nativeLabel = "com.mikerosoft.voice-type-native"
    public static let nativeBundleID = "com.mikerosoft.voice-type-native"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    public static var nativePlist: URL { directory.appendingPathComponent("\(nativeLabel).plist") }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Voice Type")
    }

    /// Native's agent. KeepAlive on unsuccessful exit restarts it after a crash or a watchdog
    /// (which exits 75), but not after Quit (exit 0). A wake doesn't restart it, so 10 s
    /// (launchd's default) between restarts is plenty. AssociatedBundleIdentifiers lets
    /// Login Items show the app's name.
    public static func nativePlistContents(executable: String, logDirectory: URL = logDirectory) -> String {
        let log = logDirectory.appendingPathComponent("native-launchd.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(nativeLabel))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(xmlEscape(executable))</string>
          </array>
          <key>AssociatedBundleIdentifiers</key>
          <string>\(xmlEscape(nativeBundleID))</string>
          <key>StandardOutPath</key>
          <string>\(xmlEscape(log))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscape(log))</string>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
        </dict>
        </plist>

        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Gets launchd running native's agent: enables it if it's disabled (so it starts at login
    /// again; older builds disabled it to hand the hotkey to the Python version), then
    /// kickstarts it if it's loaded or bootstraps it if not. Kickstarting a copy that's
    /// already running leaves it alone.
    public static func start(_ launch: LaunchControl, plist: URL = nativePlist,
                             checkPlist: (URL, String) -> String? = { LaunchAgentCheck.problem(with: $0, label: $1) }) throws {
        if launch.isDisabled(nativeLabel) { try launch.enable(nativeLabel) }
        if launch.isLoaded(nativeLabel) {
            try launch.kickstart(nativeLabel, restart: false)
            return
        }
        // A broken plist would only say "Bootstrap failed: 5: Input/output error".
        if let problem = checkPlist(plist, nativeLabel) { throw LaunchctlError("\(problem). Run native/scripts/build-app.sh to install it again.") }
        try launch.bootstrap(plist)
    }
}

/// `launchctl` in the user's GUI domain.
public protocol LaunchControl: AnyObject {
    func isLoaded(_ label: String) -> Bool
    func isDisabled(_ label: String) -> Bool
    func enable(_ label: String) throws
    func bootstrap(_ plist: URL) throws
    /// `kickstart`, with `-k` when `restart` is set.
    func kickstart(_ label: String, restart: Bool) throws
}

public struct LaunchctlError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Checks a LaunchAgent before bootstrapping it, so a broken one gets a useful error. Nil when
/// it's fine.
public enum LaunchAgentCheck {
    public static func problem(with url: URL, label: String, fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "\(url.path) is missing" }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "\(url.path) isn't a valid property list"
        }
        guard plist["Label"] as? String == label else { return "\(url.path) isn't the agent for \(label)" }
        guard let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String else {
            return "\(url.path) has no program to run"
        }
        guard fileExists(program) else { return "\(url.path) runs \(program), which isn't there" }
        return nil
    }
}
