// voice-type-native: the native dictation pipeline without the app.
//
// Nothing here touches the keyboard tap, the microphone or Python's instance lock, so it's
// safe to run while either app is dictating. settings.json and the recordings are only read.

import Foundation
import VoiceTypeCore
import VoiceTypeWhisper

let cli = CLI(options: parseOptions(Array(CommandLine.arguments.dropFirst())))

switch cli.options.command {
case "transcribe": cli.transcribe()
case "serve": cli.serve()
case "replay": cli.replay()
case "tokens": cli.tokens()
case "":
    print(usage)
    exit(2)
default:
    fail("unknown command \(cli.options.command)\n\n\(usage)")
}
