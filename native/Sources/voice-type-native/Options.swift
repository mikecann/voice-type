import Foundation
import VoiceTypeCore

let usage = """
    usage: voice-type-native COMMAND [options]

    commands:
      transcribe FILE.wav     print the text Voice Type would type for a recording
      serve                   answer whispercpp-bench's line protocol on stdin/stdout
      replay --since DATE     rerun saved recordings (UTC date, e.g. 2026-10-20) and print
                              where the text differs from what was typed at the time
      tokens                  show the word list prompt's tokens, ours and whisper.cpp's
      composite IN.png OUT.png --rect X,Y,W,H [--marks FILE.json]
                              draw screen marks onto a capture the way the app does
                              (marks: [{"number": 1, "points": [[x, y], ...]}], in points)

      history [N]             list the last N dictations (default 20) as the History
                              window shows them

    running the app (these never need the app to be working):
      status                  what Voice Type Native is doing
      show [WINDOW]           open a window in the running app: settings (default),
                              words, permissions or history
      restart                 restart Voice Type Native once it's idle (or start it if
                              it isn't running), and wait until it's ready again
                              (--force restarts straight away)
      launch-agent-plist EXE  print the LaunchAgent for an installed app (build script)
      snapshot-windows DIR    save PNGs of the settings and history windows (shown behind
                              every other window for a moment, without taking focus)

    options:
      --raw                   run only Whisper: no gates, loop guard or corrections
      --word-timings          serve: time each word (whisper.cpp's token timestamps)
      --dtw                   serve: time words with a DTW context instead, as the app's
                              timing pass for screen marks does (flash attention off, so
                              the text can differ)
      --model PATH            ggml model (default: <data>/models/ggml-large-v3-turbo-q8_0.bin)
      --settings PATH         settings.json to read (default: <data>/settings.json)
      --recordings DIR        recordings folder for replay (default: <data>/recordings)
      --json PATH             replay: also write each recording's result as JSON
      --threads N             CPU threads for whisper.cpp (default 4)
      --no-gpu                run on the CPU only
      --force                 restart: don't wait for the dictation to finish
      --rect X,Y,W,H          composite: what the capture covers, in Quartz points
      --marks FILE            composite: the marks to draw (none without it)

    <data> is $VOICE_TYPE_DATA_DIR or ~/Library/Application Support/Voice Type.
    """

struct Options {
    var command = ""
    var positional: [String] = []
    var raw = false
    var wordTimings = false
    var dtw = false
    var model = VoiceTypePaths.defaultModel.path
    var settings = VoiceTypePaths.settingsFile
    var recordings = VoiceTypePaths.recordingsDirectory
    var since: String?
    var json: String?
    var threads: Int32 = 4
    var useGPU = true
    var force = false
    var rect: String?
    var marks: String?
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
        case "--word-timings": options.wordTimings = true
        case "--dtw": options.dtw = true
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
        case "--rect": options.rect = value(for: arg)
        case "--marks": options.marks = (value(for: arg) as NSString).expandingTildeInPath
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
            if options.command.isEmpty { options.command = arg } else { options.positional.append(arg) }
        }
    }
    return options
}
