// voice-type-native: Voice Type Native's app and its command line, in one executable.
//
// Launched as Voice Type Native.app (by launchd, or opened), with no arguments, it's the
// menu bar app. Otherwise it's the command line. transcribe, serve, replay and tokens never
// touch the keyboard tap, the microphone or Python's instance lock, so they're safe to run
// while either app is dictating; settings.json and the recordings are only read.

import Foundation
import VoiceTypeCore
import VoiceTypeMac

// Old versions of Launch Services add a -psn_ argument when opening an app.
let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
// launchd and Launch Services (Finder, Spotlight, `open`) both start apps with launchd as the
// parent. Run from a terminal, even through a link into the bundle, it stays a command line,
// so the app never starts with the terminal's permissions.
if arguments.isEmpty && Bundle.main.bundleIdentifier == LaunchAgents.nativeBundleID && getppid() == 1 {
    NativeApp.run()
}

let options = parseOptions(arguments)
let cli = CLI(options: options)
let service = ServiceCommands(options: options)

switch options.command {
case "transcribe": cli.transcribe()
case "serve": cli.serve()
case "replay": cli.replay()
case "tokens": cli.tokens()
case "status": service.status()
case "switch": service.switchTo()
case "restart": service.restart()
case "launch-agent-plist": service.launchAgentPlist()
case "":
    print(usage)
    exit(2)
default:
    fail("unknown command \(options.command)\n\n\(usage)")
}
