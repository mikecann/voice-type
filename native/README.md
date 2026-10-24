# Voice Type Native

The native Swift rewrite of Voice Type, planned in [PLAN.md](PLAN.md). Phase 1 is done apart from being tried on real hardware: a menu bar app that does everything the Python app does except drawing on screen, sharing its settings, recordings and history, so you can switch between the two whenever you like. It runs whisper.cpp large-v3-turbo q8_0 on Metal and decodes exactly as the benchmark's whispercpp-bench does.

## Building and testing

You need Xcode 27 on an Apple Silicon Mac running macOS 26.

```
cd native
swift build -c release
swift test
```

The first build downloads ggml-org's whisper.cpp xcframework (release b5454, about 66 MB) into `.build`. Package.swift pins its checksum, so nothing binary lives in git.

`swift test` runs everything that needs no hardware: the ported Python tests, the controller, paste flow, recordings, history, switching and watchdogs against fakes, and the resampler. Nothing in it opens the keyboard tap, the microphone or the pasteboard, or calls launchctl. The whisper tests skip themselves unless the model is at the default path below or you point at it:

```
VOICE_TYPE_TEST_MODEL=/path/to/ggml-large-v3-turbo-q8_0.bin swift test
```

`scripts/make-python-fixtures.py` regenerates the files in `Tests/VoiceTypeCoreTests/Fixtures/python` with the Python app's own recording_archive.py, transcription_history.py and json.dump, which the tests compare against byte for byte.

## Installing the app

```
native/scripts/build-app.sh
```

This builds the app, signs it and its whisper.framework with "Apple Development: Michael Cann (4BAC88BW64)", checks the designated requirement with `codesign -d -r-`, and installs it to `~/Applications/Voice Type Native.app`. It also copies the speech model into `~/Library/Application Support/Voice Type/models` if it isn't there (from the benchmark folder, or downloaded, checked against a pinned SHA-256), writes `~/Library/LaunchAgents/com.mikerosoft.voice-type-native.plist`, and links `voice-type-native` into `~/.local/bin`.

Which app is in use comes from `launchctl print-disabled`, which `switch` sets. If Python is in use, installing leaves it alone and keeps native's LaunchAgent disabled, so only one of them starts at login. If native is in use, the script restarts it into the new build once it's idle (or, if you'd quit it from its menu, tells you how to start it).

It never signs ad hoc. An ad hoc signature ties macOS's permission grants to that one binary, so every rebuild would lose them; the Apple Development signature ties them to the bundle id and certificate name, which every rebuild keeps.

`native/scripts/build-app.sh --test-build DIR` is for testing only: it builds and ad hoc signs the app into DIR and writes the LaunchAgent there to look at, without touching the keychain, `~/Applications`, `~/Library/LaunchAgents`, Voice Type's data or launchctl. Don't install what it makes.

## First run

1. Run `native/scripts/build-app.sh`. The first time it signs, macOS asks to use the signing key in your keychain: enter your password and choose Always Allow.
2. Open `~/Applications/Voice Type Native.app`, so you can grant its permissions while Python still has the hotkey. A copy you open by hand like this only shows a crossed-out microphone in the menu bar and the permissions window: it never takes the hotkey or Python's lock, so it can't get in Python's way (even when Python restarts after a wake), and it closes itself once native's LaunchAgent is running. Grant Accessibility and Input Monitoring with their buttons (each adds Voice Type Native to the list in System Settings, where you switch it on), and click Ask now for the microphone. If there's something on your clipboard, click Check now next to Paste from other apps: macOS 26 may ask whether Voice Type Native can read the clipboard, and you want Allow, since it copies your clipboard before pasting so it can put it back afterwards. (If you skip this step, step 3 still works and native opens the same window, but dictation waits until the grants are done.)
3. Choose Switch to Voice Type Native from its menu, or run `voice-type-native switch native`. That waits for Python to finish any dictation and pauses it, stops it and disables its LaunchAgent, then starts native's, which is the copy that dictates from then on.
4. Hold F12 or Right Control and talk. The pill comes up red as soon as audio arrives, shows the live preview, turns orange while Whisper finishes and green with the word count when the text lands. "On your clipboard" means no text box took it, so Cmd+V it yourself.

## Switching

```
voice-type-native switch native    # or Switch to Voice Type Native in its menu
voice-type-native switch python    # or Switch to Python Voice Type in its menu
voice-type-native status           # what each app is doing
voice-type-native restart          # restart native once it's idle, wait until it's ready
```

Switching doesn't cut off a dictation. The app you're leaving stops taking new ones first: Python is paused through its control socket the moment it says it's idle (there's a gap of one socket round trip, a millisecond or so, where a key press could still get in), and native, asked by `switch python`, hands over itself from its own queue, where a key press can't slip in at all. Then it waits for a dictation that's still finishing, checks again, and stops the app, including a copy launchd didn't start (a Python run by hand or from Spotlight), and checks Python's lock is free before starting the other one. It disables one LaunchAgent and enables the other, so the choice survives a reboot. Both agents are checked before anything changes, and if the other app won't start, everything is put back as it was, so you're never left with neither. The command line works without the app, so `switch python` gets you back even if native is broken. Python's own grants are untouched, so it works straight away.

Native also holds Python's `voice-type.instance.lock` and keeps its heartbeat fresh, so a Python worker started by mistake (from Spotlight or `voice-type`) exits quietly, and native never turns its keyboard tap on without that lock. Only the copy launchd starts ever takes it, and it leaves it alone while Python's LaunchAgent is still enabled. `voice-type` (Python's restart script) still only restarts Python; while native is in use it'll start a Python worker that exits straight away and then report that it didn't become ready.

`restart` sends the app SIGUSR1. The app waits until nothing is being dictated, exits with 75, and launchd starts a fresh copy; the command waits until the new one says it's ready. `restart --force` restarts straight away.

## When something keeps failing

If Core Audio or Metal hangs (a watchdog fires, a microphone call doesn't return in 2 s, the microphone gives nothing for 45 s after a wake), native exits with 75 and launchd starts a fresh copy, as Python did at every wake. If that keeps happening (a corrupt model, say), the restarts back off: the first is immediate, then 30 s, 2 minutes and 5 minutes, and after five in half an hour it stops trying. The menu then shows what went wrong and a Try Again item, and F12 and Right Control work as normal keys until you fix it. `voice-type-native restart` (which the build script runs) also starts it afresh. F12 and Right Control also go through as normal keys while dictation is paused from the menu or the model is missing.

## What it shares with Python

Everything lives in `~/Library/Application Support/Voice Type` (or `$VOICE_TYPE_DATA_DIR`).

- `settings.json`: native reads `microphone_name`, `vocabulary`, `corrections` and `audio_recording_enabled` (and `draw_on_screen_enabled`, for phase 2), notices when the file changes, and when you pick a microphone from its menu rewrites the file as Python would, keeping every other key. Native-only settings go under `"native"`.
- `recordings/`: the same float WAVs and JSON, byte for byte, with the same statuses and 30-day cleanup. Native adds `app: "native"`, `engine`, `segments` (with no-speech and token probabilities) and `timings`. A near-silent clip of a second or more that Whisper turned into one of its silence phrases (the "Thank you." case) is saved as `skipped_low_level` with `skip_reason: "long_near_silent"` and what Whisper heard in `raw_transcript`; quiet real words in a clip that level still get typed.
- `transcription-history.jsonl`: the same lines, mode `final_only`.
- `models/ggml-large-v3-turbo-q8_0.bin`: native's model.
- `native-status.json`: what native is doing, for the command line.
- `native-restarts.json`: recent failed restarts, for the backoff.

The log is `~/Library/Logs/Voice Type/voice-type-native.log`, in the same format as Python's. It rotates while the app runs (past 1 MB it keeps the last 2,000 lines), and the live preview gets one line per dictation rather than one every half second. launchd's output goes to `native-launchd.log` next to it, which now only gets what the process prints itself (a crash, say) and is trimmed at launch. A watchdog that fires writes every thread's stack to `voice-type-native-hang-<time>.txt` there before the app exits for launchd to restart it (only for the first two restarts in half an hour).

If macOS won't let Voice Type Native read the clipboard (Paste from other apps set to Deny, or Don't Allow on its prompt), it can't put your clipboard back after a paste, so the dictated text stays on the clipboard instead, and the pill says so once. Allow it in System Settings > Privacy & Security, or from the permissions window.

## Testing the engine against the benchmark

None of these commands touch the keyboard tap, the microphone or the Python app's lock, so they're safe to run while Voice Type is dictating. settings.json and the recordings are only ever read. Pass `--model` until the app has put the model in place (the benchmark's copy is `~/dev/me/voice-type-benchmark/models/whispercpp/ggml-large-v3-turbo-q8_0.bin`).

```
# What Voice Type would type for a recording
.build/release/voice-type-native transcribe clip.wav --model PATH

# The benchmark's line protocol on stdin and stdout
.build/release/voice-type-native serve --model PATH

# Rerun saved recordings since a UTC date and show where the text differs
# from what the Python app typed
.build/release/voice-type-native replay --since 2026-10-20 --model PATH

# The word list prompt's tokens, ours and whisper.cpp's
.build/release/voice-type-native tokens --model PATH
```

By default each command runs the whole pipeline the way the app does: the flatline and short-clip gates, the 0.3 s minimum, Whisper, the repetition loop guard, the "Thank you." check on near-silent clips, then your corrections. `--raw` runs Whisper alone (still with the word list prompt, since that's part of how it decodes).

`serve` reads one JSON request per line, `{"id": ..., "path": FILE}`, where FILE is raw 16 kHz float32 (what the benchmark writes) or a WAV. It answers with the text, Whisper's time in `ms`, the segments, and the gate's status and levels. If a request carries `prompt_tokens` they're used as given; leave them out to test the native tokenizer.

`scripts/parity.py` runs the labelled short clips and the 2026-10-20 review batch through `serve` and compares the text with the benchmark's saved whisper.cpp output:

```
python3 native/scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH --raw
python3 native/scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH
```

## Layout

- `Sources/VoiceTypeCore`: every decision, with no AppKit, Core Audio or whisper in it, so it's all tested: settings, the word list prompt and tokenizer, the gates, loop guard and corrections, the recording archive and history (Python's bytes), the controller's state machine, microphone readiness and stream logic, the paste flow, the pill's timings, watchdogs and the restart backoff, the lock, switching and the status file.
- `Sources/VoiceTypeWhisper`: the whisper.cpp engine, the only code that calls whisper.cpp.
- `Sources/VoiceTypeMac`: the thin layer that touches the Mac, behind VoiceTypeCore's protocols: the keyboard tap, Core Audio input and resampling, NSPasteboard, Accessibility and Cmd+V, launchctl, the menu bar item, the pill and the permissions window.
- `Sources/voice-type-native`: one executable, the app when launched from its bundle and the command line otherwise.
- `scripts/build-app.sh`: build, sign, install. `scripts/parity.py`: the benchmark check. `scripts/make-python-fixtures.py`: Python's files for the tests.

Why the tokenizer is our own: whisper.cpp's `whisper_tokenize` picks the longest matching token at each step, while Whisper was trained on tiktoken's byte-pair encoding. They split Claude, Tailscale, Vercel and Parakeet differently, so the prompt wouldn't be the one the benchmark measured. `WhisperBPETokenizer` repeats tiktoken's rules using the ranks in the model file and gives the same 55 tokens as mlx-whisper for today's word list.
