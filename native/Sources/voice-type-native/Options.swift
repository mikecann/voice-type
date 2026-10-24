import Foundation
import VoiceTypeCore

let usage = """
    usage: voice-type-native COMMAND [options]

    commands:
      transcribe FILE.wav     print the text Voice Type would type for a recording
      serve                   answer whispercpp-bench's line protocol on stdin/stdout
      replay --since DATE     rerun saved recordings (UTC date, e.g. 2026-10-20) and print
                              where the text differs from what the Python app typed
      tokens                  show the word list prompt's tokens, ours and whisper.cpp's

    running the app (these never need the app to be working):
      status                  what Voice Type Native and the Python app are doing
      switch native|python    hand the hotkey to one app: waits for the other to finish
                              any dictation, then flips their LaunchAgents
      restart                 restart Voice Type Native once it's idle, and wait until
                              it's ready again (--force restarts straight away)
      launch-agent-plist EXE  print the LaunchAgent for an installed app (build script)

    options:
      --raw                   run only Whisper: no gates, loop guard or corrections
      --model PATH            ggml model (default: <data>/models/ggml-large-v3-turbo-q8_0.bin)
      --settings PATH         settings.json to read (default: <data>/settings.json)
      --recordings DIR        recordings folder for replay (default: <data>/recordings)
      --json PATH             replay: also write each recording's result as JSON
      --threads N             CPU threads for whisper.cpp (default 4)
      --no-gpu                run on the CPU only
      --force                 restart: don't wait for the dictation to finish

    <data> is $VOICE_TYPE_DATA_DIR or ~/Library/Application Support/Voice Type.
    """

struct Options {
    var command = ""
    var positional: [String] = []
    var raw = false
    var model = VoiceTypePaths.defaultModel.path
    var settings = VoiceTypePaths.settingsFile
    var recordings = VoiceTypePaths.recordingsDirectory
    var since: String?
    var json: String?
    var threads: Int32 = 4
    var useGPU = true
    var force = false
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("voice-type-native: \(message)\n".utf8))
    exit(code)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var args = arguments[...]
    func value(for flag: String) -> String {
        guard let next = args.popFirst() else { fail("\(flag) needs a value") }
        return next
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--raw": options.raw = true
        case "--model": options.model = (value(for: arg) as NSString).expandingTildeInPath
        case "--settings": options.settings = URL(fileURLWithPath: (value(for: arg) as NSString).expandingTildeInPath)
        case "--recordings": options.recordings = URL(fileURLWithPath: (value(for: arg) as NSString).expandingTildeInPath)
        case "--since": options.since = value(for: arg)
        case "--json": options.json = value(for: arg)
        case "--threads":
            guard let n = Int32(value(for: arg)), n > 0 else { fail("--threads needs a positive number") }
            options.threads = n
        case "--no-gpu": options.useGPU = false
        case "--force": options.force = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
            if options.command.isEmpty { options.command = arg } else { options.positional.append(arg) }
        }
    }
    return options
}
