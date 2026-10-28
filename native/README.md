# Voice Type Native

Voice Type as a Swift menu bar app, planned in [PLAN.md](PLAN.md). Phases 1 and 2 are built: dictation, and drawing on screen while you talk. It runs whisper.cpp large-v3-turbo q8_0 on Metal and decodes exactly as the benchmark's whispercpp-bench does. It replaced the original Python version, which was removed after commit 17e8220, and it reads and writes that version's settings, recordings, history and screenshots in the same formats, so nothing was lost in the move.

## Building and testing

You need Xcode 27 on an Apple Silicon Mac running macOS 26.

```
cd native
swift build -c release
swift test
```

The first build downloads ggml-org's whisper.cpp xcframework (release b5454, about 66 MB) into `.build`. Package.swift pins its checksum, so nothing binary lives in git.

`swift test` runs everything that needs no hardware: the ported Python tests, the controller, paste flow, recordings, history, the lock and LaunchAgent rules and watchdogs against fakes, the resampler, and drawing (the ink tracker and mouse tap session, the capture worker, marker placement, the text-and-screenshots paste, and the screenshot compositor against Python's own output). Nothing in it opens the keyboard or mouse tap, the microphone or the pasteboard, takes a screenshot, or calls launchctl. The whisper tests skip themselves unless the model is at the default path below or you point at it:

```
VOICE_TYPE_TEST_MODEL=/path/to/ggml-large-v3-turbo-q8_0.bin swift test
```

The files in `Tests/VoiceTypeCoreTests/Fixtures/python` were written by the Python version's own recording_archive.py, transcription_history.py and json.dump, and the tests compare against them byte for byte. `Fixtures/marks` is three synthetic window captures and what the Python version's composite_png (in mark_capture.py) made of them, with and without marks. They were generated from the Python version, which was removed after commit 17e8220. To regenerate them, check out that commit and run its `native/scripts/make-python-fixtures.py` or `native/scripts/make-mark-fixtures.py` (the second needs Pillow).

## Installing the app

```
native/scripts/build-app.sh
```

This builds the app, signs it and its whisper.framework with "Apple Development: Michael Cann (4BAC88BW64)", checks the designated requirement with `codesign -d -r-`, and installs it to `~/Applications/Voice Type Native.app`. It also copies the speech model into `~/Library/Application Support/Voice Type/models` if it isn't there (from the benchmark folder, or downloaded, checked against a pinned SHA-256), writes `~/Library/LaunchAgents/com.mikerosoft.voice-type-native.plist`, and links `voice-type-native` into `~/.local/bin`.

Then it makes sure the LaunchAgent isn't disabled, so the app starts at login, and gets it running. A running app restarts into the new build once it's idle, one you'd quit from its menu is started again, and on a first install the agent is loaded, which starts it.

It never signs ad hoc. An ad hoc signature ties macOS's permission grants to that one binary, so every rebuild would lose them; the Apple Development signature ties them to the bundle id and certificate name, which every rebuild keeps.

`native/scripts/build-app.sh --test-build DIR` is for testing only: it builds and ad hoc signs the app into DIR and writes the LaunchAgent there to look at, without touching the keychain, `~/Applications`, `~/Library/LaunchAgents`, Voice Type's data or launchctl. Don't install what it makes.

## First run

1. Run `native/scripts/build-app.sh`. The first time it signs, macOS asks to use the signing key in your keychain: enter your password and choose Always Allow. The script then starts the app from its LaunchAgent.
2. If a permission it needs is missing, the app opens its settings on the Permissions tab. Grant Accessibility and Input Monitoring with their buttons (each adds Voice Type Native to the list in System Settings, where you switch it on), and click Ask now for the microphone. If there's something on your clipboard, click Check now next to Paste from other apps: macOS 26 may ask whether Voice Type Native can read the clipboard, and you want Allow, since it copies your clipboard before pasting so it can put it back afterwards. The keyboard tap is retried every 2 seconds, so dictation starts working as soon as the grants are done.
3. Hold F12 or Right Control and talk. The pill comes up red as soon as audio arrives, shows the live preview, turns orange while Whisper finishes and green with the word count when the text lands. "On your clipboard" means no text box took it, so Cmd+V it yourself. If the focus was on a button, a link or a tab instead, the pill says so: click the text box, then Cmd+V. The log has a line for every paste that wasn't read, with what had focus, which app was in front and whether Voice Type's main thread was answering.

## Running it

```
voice-type-native status           # what it's doing
voice-type-native restart          # restart it once it's idle (or start it), wait until it's ready
voice-type-native show history     # open a window: settings (the default), words, permissions or history
voice-type-native history 50       # the last 50 dictations, as the History window lists them
```

`restart` sends the app SIGUSR1. The app waits until nothing is being dictated, exits with 75, and launchd starts a fresh copy; the command waits until the new one says it's ready. `restart --force` restarts straight away, and if the app isn't running (you quit it from its menu, say) `restart` starts it. Both commands work without the app, so they still help when it's broken.

Only one copy dictates. The one launchd starts holds `voice-type.instance.lock` in the data folder, and never turns its keyboard tap on without it. Opening the app from Finder or Spotlight while it's running brings up its settings (a second copy quits straight away). If it isn't running, the copy you opened starts launchd's and quits, so the copy that dictates is always launchd's and restarts the same way.

## Settings and history

**Settings** (Settings... in the menu, or open the app from Spotlight) has three tabs. General: dictation on or off, the microphone, whether recordings are kept, drawing on screen and its marker timing, and Open Log, Open Data Folder and Restart. Words: the word list Whisper is given and the corrections applied after it (what it hears on the left, what to type on the right, run in order). Permissions: each grant, with a button to ask for it or open the right page of System Settings. Everything is written to settings.json straight away (edits to the word list half a second after you stop typing) and used from the next key-down. Only what you changed is applied, so a word added to the file by hand while the window is open stays. The ⓘ next to a setting says what it does.

**History** (History... in the menu) lists the last 30 days of dictations, newest first, from the recordings and the history file. Click one to copy it, or search. Each has a play button while its audio is kept, thumbnails of any screenshots (7 days), and a menu with:

- **Fix It**: type what you actually said. It's saved in the recording as `corrected_text`, and the recording is copied into `labelled/` in the data folder, which is never cleaned up, so the benchmark gets a labelled clip that outlives the 30 days.
- **Transcribe Again**: runs Whisper on the saved audio without the gates, for a clip that was skipped as too quiet, say, one at a time. The result goes in the recording as `retranscribed_text` and shows in grey; it isn't typed anywhere.
- **Show in Finder**.

**Crash safety.** While the key is held, the audio is also written to `recordings/<id>.wav.partial` (only when recordings are kept), and deleted once the recording is saved properly at key-up. If the app goes down mid-dictation (a crash, a watchdog, `restart --force`), the next launch turns that file into a recording, transcribes it with your word list and corrections, and adds it to the history with `recovered: true`; a recording that was saved but never transcribed (the app went down after key-up) is picked up the same way. It's never pasted, since whatever it was for has moved on: the pill says "Recovered" and the menu has a Recovered item that opens History. Only the last two days are looked at, and each attempt is counted in the recording before Whisper sees it, with two allowed, so one that brings the app down isn't tried at every launch. A restart or Quit while it's recovering waits for it to finish, as it does for a dictation.

**The 120 s cap.** A dictation stops itself after two minutes, in case the key looks stuck. For the last 10 seconds the pill's REC counts down, so it doesn't stop mid-sentence without warning.

## When something keeps failing

If Core Audio or Metal hangs (a watchdog fires, a microphone call doesn't return in 2 s, the microphone gives nothing for 45 s after a wake), native exits with 75 and launchd starts a fresh copy, as Python did at every wake. If that keeps happening (a corrupt model, say), the restarts back off: the first is immediate, then 30 s, 2 minutes and 5 minutes, and after five in half an hour it stops trying. The menu then shows what went wrong and a Try Again item, and F12 and Right Control work as normal keys until you fix it. `voice-type-native restart` (which the build script runs) also starts it afresh. F12 and Right Control also go through as normal keys while dictation is paused from the menu or the model is missing.

## Drawing while you talk

Hold F12 or Right Control, talk, and click or drag on the screen. A click leaves a ring, a straight drag an arrow, and anything else (a circle, a scribble) stays as you drew it, each with a number. Moving the mouse without a button pressed works as normal, and nothing reaches the app underneath while you draw, from the moment the key goes down, even if the microphone is still opening. When you let go, the text goes in with `[1]`, `[2]` and so on where you were talking when you finished each mark, then a screenshot of each window you drew on, each as its own Cmd+V 0.35 s apart, and the clipboard is put back once at the end. Marks on the same window share one screenshot. If you draw but don't say anything, only the screenshots are pasted. Up to 10 marks per dictation.

- **The mouse.** A second event tap, on the same thread as the keyboard's, watches only left mouse down, drag and up, and is only switched on for the length of a dictation. It stops swallowing the moment the key goes up, on the tap's own thread. A drag already under way when you press the key belongs to the app; if you let go of the key mid-drag the mark ends there and the mouse-up that's owed is swallowed (given up after 5 s if it never comes); a press still owed from the last dictation stays yours in the next; and after a tap timeout, a wake or a keyboard tap timeout Voice Type lets go of the button. A watchdog checks four times a second while the tap is on.
- **The ink** is drawn live on a click-through panel on each display you draw on, which never takes focus and is left out of screenshots. The panels are closed once the ink has gone, so they don't hold on to their memory between dictations.
- **Screenshots.** Each mark captures the window under it with `screencapture -x -o -l <window>`, or an 800-point region of the display over bare desktop, on a worker while you're still holding the key. Ink and numbers are drawn with Core Graphics, then the image is shrunk to a 1568 px long edge and saved as a 256-colour PNG, using ports of the same Pillow resize and quantizer Python used, so they come out the same (about 100 to 190 KB for a typical window). They're saved in `screenshots/` under the data folder and deleted after 7 days.
- **Markers** need each word's time. The text always comes from the normal pass; a dictation with marks then gets a second, timing-only pass in another whisper.cpp context that aligns the words the way mlx-whisper did for Python (DTW over the model's alignment heads, which needs flash attention off, hence the second context). That context is about 1 GB: it's loaded on its own thread once your first mark of a dictation has been captured, usually before you let go, and freed 5 minutes after your last mark (sleep counts) or when the Mac wakes. The pass adds about 0.4 s before the paste on a short dictation. If it can't load, or takes longer than 4 s plus 0.1 s per second of audio, the normal pass's own token timestamps are used, which are rougher, and the words still go in. To skip the timing pass and its memory altogether, set Marker timing to Rough in Settings (it's `"native": {"marker_timings": "rough"}` in settings.json; `"accurate"` is the default); it applies from the next key-down.
- **Screen Recording.** The first time you draw without it, your words still paste, the pill says "No screenshots" and macOS asks. Switch on Voice Type Native under System Settings > Privacy & Security > Screen & System Audio Recording (or use the button on the Permissions tab in Settings), then run `voice-type-native restart`.
- Turn it off with Draw on screen in Settings (`draw_on_screen_enabled` in settings.json); native picks it up at the next key-down.

To check the compositor without holding the key:

```
.build/release/voice-type-native composite capture.png out.png --rect X,Y,W,H --marks marks.json
```

`--rect` is what the capture covers in screen points and `marks.json` is `[{"number": 1, "points": [[x, y], ...]}]` in the same points.

## Data

Everything lives in `~/Library/Application Support/Voice Type` (or `$VOICE_TYPE_DATA_DIR`), the folder the Python version used, in the formats it wrote, so older settings, recordings and history carry on.

- `settings.json`: native reads `microphone_name`, `vocabulary`, `corrections`, `audio_recording_enabled` and `draw_on_screen_enabled`, notices when the file changes (so a hand edit works too), and when you change something in Settings or pick a microphone from the menu rewrites the file in the same format, keeping every other key. The keys only the Python version used (`final_model`, `stream_model`, `output_mode` and `formatter_*`) are removed at launch. Native-only settings go under `"native"`: so far just `marker_timings` (`"accurate"` or `"rough"`, see Markers above).
- `recordings/`: the same float WAVs and JSON the Python version wrote, byte for byte, with the same statuses and 30-day cleanup, and for dictations with marks the same `mark_count`, `screenshots` and `text` with markers (`decoded_text` is without). Native adds `app: "native"`, `engine`, `segments` (with no-speech and token probabilities) and `timings`, and from the History window and crash recovery `corrected_text` and `corrected_at` (Fix It), `retranscribed_text` (Transcribe Again), and `recovered`, `recovered_from: "partial"` and `recovery_attempts`. A `<id>.wav.partial` is the audio of a dictation in progress (see Crash safety). A near-silent clip of a second or more that Whisper turned into one of its silence phrases (the "Thank you." case) is saved as `skipped_low_level` with `skip_reason: "long_near_silent"` and what Whisper heard in `raw_transcript`; quiet real words in a clip that level still get typed.
- `transcription-history.jsonl`: the same lines, mode `final_only`.
- `screenshots/`: the same file names, so ones the Python version left are deleted after 7 days too.
- `labelled/`: the recordings you fixed in History, WAV and JSON, kept for good.
- `models/ggml-large-v3-turbo-q8_0.bin`: native's model.
- `native-status.json`: what native is doing, for the command line. Only the copy holding the lock writes it.
- `voice-type.instance.lock`: held by the copy that dictates.
- `native-restarts.json`: recent failed restarts, for the backoff.

The log is `~/Library/Logs/Voice Type/voice-type-native.log`, in the same format as Python's. It rotates while the app runs (past 1 MB it keeps the last 2,000 lines), and the live preview gets one line per dictation rather than one every half second. launchd's output goes to `native-launchd.log` next to it, which now only gets what the process prints itself (a crash, say) and is trimmed at launch. A watchdog that fires writes every thread's stack to `voice-type-native-hang-<time>.txt` there before the app exits for launchd to restart it (only for the first two restarts in half an hour).

If macOS won't let Voice Type Native read the clipboard (Paste from other apps set to Deny, or Don't Allow on its prompt), it can't put your clipboard back after a paste, so the dictated text stays on the clipboard instead, and the pill says so once. Allow it in System Settings > Privacy & Security, or from the Permissions tab in Settings.

## Testing the engine against the benchmark

None of these commands touch the keyboard tap, the microphone or the instance lock, so they're safe to run while Voice Type is dictating. settings.json and the recordings are only ever read. Pass `--model` until the app has put the model in place (the benchmark's copy is `~/dev/me/voice-type-benchmark/models/whispercpp/ggml-large-v3-turbo-q8_0.bin`).

```
# What Voice Type would type for a recording
.build/release/voice-type-native transcribe clip.wav --model PATH

# The benchmark's line protocol on stdin and stdout
.build/release/voice-type-native serve --model PATH

# Rerun saved recordings since a UTC date and show where the text differs
# from what was typed at the time
.build/release/voice-type-native replay --since 2026-10-20 --model PATH

# The word list prompt's tokens, ours and whisper.cpp's
.build/release/voice-type-native tokens --model PATH
```

`serve --word-timings` also times every word, as the app does for a dictation with marks, and returns the times with each segment.

By default each command runs the whole pipeline the way the app does: the flatline and short-clip gates, the 0.3 s minimum, Whisper, the repetition loop guard, the "Thank you." check on near-silent clips, then your corrections. `--raw` runs Whisper alone (still with the word list prompt, since that's part of how it decodes).

`serve` reads one JSON request per line, `{"id": ..., "path": FILE}`, where FILE is raw 16 kHz float32 (what the benchmark writes) or a WAV. It answers with the text, Whisper's time in `ms`, the segments, and the gate's status and levels. If a request carries `prompt_tokens` they're used as given; leave them out to test the native tokenizer.

`scripts/parity.py` runs the labelled short clips and the 2026-10-20 review batch through `serve` and compares the text with the benchmark's saved whisper.cpp output:

```
python3 native/scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH --raw
python3 native/scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH
```

Add `--word-timings` to either to check that timing words doesn't change the text.

`scripts/marker-check.py`, which compared native's word timings with mlx-whisper's to check where markers land (PLAN.md's phase 2 result has the numbers), ran the Python version's code, so it went with it after commit 17e8220.

## Layout

- `Sources/VoiceTypeCore`: every decision, with no AppKit, Core Audio or whisper in it, so it's all tested: settings, the word list prompt and tokenizer, the gates, loop guard and corrections, the recording archive and history (in the Python version's bytes), the controller's state machine, microphone readiness and stream logic, the recording spool and crash recovery, the History list and labels, the paste flow, the pill's timings, watchdogs and the restart backoff, the lock rules, the LaunchAgent and the status file. And drawing: stroke shapes, windows and coordinates (ScreenMarks), the ink tracker and mouse tap session, the capture worker, the screenshot store, marker placement, and drawing ink with Core Graphics.
- `Sources/VoiceTypeImaging`: ports of Pillow's LANCZOS resize and FASTOCTREE quantizer and its palette PNG output, always built optimised (unoptimised Swift takes seconds per screenshot).
- `Sources/VoiceTypeWhisper`: the whisper.cpp engine, the only code that calls whisper.cpp.
- `Sources/VoiceTypeMac`: the thin layer that touches the Mac, behind VoiceTypeCore's protocols: the keyboard and mouse taps, Core Audio input and resampling, NSPasteboard, Accessibility and Cmd+V, launchctl, the menu bar item, the pill, the live ink, the window list and `screencapture`, and the settings and history windows (SwiftUI, built when opened and let go when closed). `voice-type-native snapshot-windows DIR` saves PNGs of them, from windows put behind all your others for a couple of seconds, so nothing takes focus.
- `Sources/voice-type-native`: one executable, the app when launched from its bundle and the command line otherwise.
- `scripts/build-app.sh`: build, sign, install. `scripts/parity.py`: the benchmark check.

Why the tokenizer is our own: whisper.cpp's `whisper_tokenize` picks the longest matching token at each step, while Whisper was trained on tiktoken's byte-pair encoding. They split Claude, Tailscale, Vercel and Parakeet differently, so the prompt wouldn't be the one the benchmark measured. `WhisperBPETokenizer` repeats tiktoken's rules using the ranks in the model file and gives the same 55 tokens as mlx-whisper for today's word list.
