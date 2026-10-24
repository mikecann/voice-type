# Voice Type native: the plan

## In short

A Swift menu bar app called Voice Type Native (bundle ID `com.mikerosoft.voice-type-native`), in a `native/` folder in this repo. It runs whisper.cpp large-v3-turbo q8_0 on Metal and shares settings.json, recordings and history with the Python version, so the benchmark keeps working and you can switch back any time. Phase 1 replaces your daily driver apart from drawing, phase 2 brings drawing back, phase 3 is settings and tidying up, phase 4 is the optional vote. Same speed as today in about 1.2 GB instead of 2.3 GB.

## Architecture

A normal .app with no Dock icon, a menu bar icon (status, microphone, switch to Python, quit), and its own LaunchAgent so launchd restarts it after a crash, like today. Opening it from Spotlight opens settings.

The rule: nothing slow ever runs on the tap thread or the main thread.

- **Tap thread**: its own run loop holding the keyboard tap (and the mouse tap in phase 2). The callback updates the key state and hands an event to the controller. No AppKit, logging or waiting. On a tap timeout it re-enables itself and treats it as key-up.
- **Controller**: one serial queue running a plain state machine (starting, idle, recording, finalising, disabled, needs restart). Event-driven instead of today's 100 Hz poll, with no hardware in it, so it's unit tested with fakes.
- **Audio**: a Core Audio input unit (AUHAL) converting to 16 kHz mono float, opened while idle and started on key-down, so the orange dot only shows while you talk. Its callback copies into a preallocated buffer. Start and stop have a 2 s timeout, as today.
- **Inference**: one thread owns the whisper context. Finals come before previews, and key-up uses whisper's abort callback to stop a running preview.
- **Paste**: its own queue, since it blocks until the target reads the pasteboard and that read is answered on the main thread.
- **Main thread**: AppKit only.
- **Watchdogs** on model load (180 s), finalisation (30 s or twice the clip) and audio stop. One firing logs a backtrace and exits with code 75 so launchd starts fresh.

Blocking work (whisper, paste waits, screencapture) goes on GCD queues, not Swift concurrency's shared pool.

## What gets ported, dropped and simpler

| Python | Native |
|---|---|
| platform_mac.py | Port the hotkeys (F12 and Right Ctrl via device flag 0x2000, both swallowed, Left Ctrl untouched) and the paste exactly |
| mic_stream.py, recording_session.py, audio_recovery.py, microphone_readiness.py | Port the logic: exact name match, 30 s wait for the Yeti, probe rejects digital silence, status only shows if you press the key |
| audio_gate.py, recording_archive.py, transcription_history.py, appkit_overlay.py, overlay_feedback.py, operation_watchdog.py | Port exactly, same bytes on disk |
| speech_backends.py | whisper.cpp engine. Its `carry_initial_prompt` replaces split_at_pauses |
| screen_marks.py, mark_capture.py, appkit_ink.py | Phase 2. Pillow becomes Core Graphics |
| voice_type_control.py, voice-type-mac.sh | A status file and a small CLI |
| Windows files, CUDA, the formatter, hybrid/stabilized/precompute modes, fast_final.py, inference_scheduler.py, old Parakeet wrapper, faster-whisper, model menus | Drop |
| setup_mac.sh, launcher.c, install and launch scripts, Spotlight app, process_relaunch.py, heartbeat takeover | Drop: the app bundle and launchd cover it |

Simpler: Core Audio tells us when devices change, so the PortAudio refresh and its "prepared stream got freed" bugs go. The pill and ink are plain AppKit without Tk's polling.

Behaviour that must survive, each from a real bug in the git log:

1. **Clipboard.** Snapshot every item and type as bytes, offer the text lazily, wait up to 2 s for the read, then ask Accessibility what has focus (0.25 s per call, 0.5 s for a stray paste to reach a text box, unknown means trust it). Restore only if nothing else was copied meanwhile. Otherwise leave the text, play Funk and show "On your clipboard" for 1.6 s. Refocus the key-down app only if another app is in front. One paste at a time.
2. **Mic ready before key-down** (it was losing about 85 ms of speech). REC shows on the first audio block. The default or a fallback mic is looked up again at key-down, and the stream reopens after a device change or error.
3. **Readiness.** No dictation until the mic probe passes and the model has warmed. 0.5 s of digital silence isn't transcribed and rebuilds the audio.
4. **Gates.** Under 1 s with rms under 0.004 and peak under 0.012 is skipped (taps under 0.4 s use 0.03), under 0.3 s is ignored, then the loop guard. These don't stop whisper.cpp's "Thank you." on near-silent clips over 1 s (found in 1a: three such clips at 1.4 to 2.5 s, peak 0.0002 to 0.0026, no-speech probability about 0). Phase 1c needs a check for those, worked out from the saved recordings' levels.
5. Audio saved before transcribing, history written before pasting, a 120 s cap, key-down ignored while finalising, and no retries, so nothing pastes twice.

Wake: today every wake restarts the process and reloads the model. Native rebuilds audio, reruns the readiness check and does one silent warm-up pass under a 10 s watchdog, exiting for a relaunch only if that fails. It never restarts mid-dictation, which is half of issue #7.

## Permissions and signing

The new bundle ID needs fresh grants once: Accessibility, Input Monitoring, Microphone, and Screen Recording in phase 2 (asked on the first drawing, as now). Python's grants stay put, so switching back works. Phase 1 should also check whether macOS 26 asks the new app for clipboard access.

Grants survive rebuilds when the signature's designated requirement doesn't change. Ad hoc signing pins it to the binary's hash, which is why today's setup refuses to rebuild the launcher. This Mac has one identity, "Apple Development: Michael Cann (4BAC88BW64)", valid until 25 September 2027. Signing with it ties the requirement to bundle ID and certificate name, which every rebuild matches. The build script signs whisper.framework and then the app with it, never falls back to ad hoc, and checks `codesign -d -r-`. No sandbox or hardened runtime. The first signing shows a keychain prompt (click Always Allow). A renewed certificate keeps its name, so at worst it's a re-grant once a year.

## Data, and switching

Shared, in `~/Library/Application Support/Voice Type/`:

- `settings.json`: native reads microphone_name, vocabulary, corrections, audio_recording_enabled and draw_on_screen_enabled, writes atomically, and keeps keys it doesn't know. Native-only settings go under `"native"`; Python already keeps unknown keys.
- `recordings/`: same names, float WAV, JSON fields, statuses and 30-day cleanup, with `final_model` still "large-v3-turbo". Adds `engine`, `app: "native"`, timings and per-segment probabilities for vote work later.
- `transcription-history.jsonl` and `screenshots/`, same formats.
- New: `models/ggml-large-v3-turbo-q8_0.bin` (copied from the benchmark, or downloaded against a pinned SHA-256) and `native-status.json`.

Logs go to `~/Library/Logs/Voice Type/voice-type-native.log`.

Only one app can own the hotkey. Switch to native (a menu item, plus `voice-type-native switch native|python` for when the app is broken) checks Python isn't mid-dictation, then uses `launchctl` to boot out and disable Python's agent and enable and start native's. Switching back does the reverse. As a backstop native holds Python's `voice-type.instance.lock`, so a Python worker started by mistake exits quietly, and native won't turn its tap on without that lock.

## Phases

### Phase 1: your daily driver, minus drawing (about 3,500 lines with tests)

- **1a, engine and CLI.** A Swift package with a pure-logic core, ggml-org's b5454 xcframework via SwiftPM's `binaryTarget(url:checksum:)` (no binaries in git), and the app. Decoding as benchmarked: English, greedy, temperature 0 with 0.2 fallback, no context, blank and non-speech tokens suppressed, 1 s max initial timestamp, flash attention. For the word list, tokenise " " plus today's prompt string with `whisper_tokenize` and test it against mlx-whisper's token IDs (55 for today's list). If they differ, ship the IDs as a fixture and see if the benchmark notices. CLI commands that never touch the tap or lock: `transcribe file.wav`, `serve` (the benchmark's line protocol, running the full pipeline of gates, engine, loop guard and corrections) and `replay --since DATE`, which diffs saved recordings against their text. Before any UI, a `vt-native` benchmark key must score within noise of `wcpp-q8-vocab` on the 173 labelled clips and the 223-clip batch.
- **1b, app shell.** Bundle, signing, LaunchAgent, menu, a build script installing to `~/Applications`, permission checks with buttons to the right System Settings pane (the tap retries once Accessibility is granted), the lock and switching.
- **1c, dictation.** Hotkey, mic, controller, pill, paste, recordings, history, watchdogs, status file, and a `restart` that waits until idle.
- **1d.** Live preview every 0.5 s, wake and device-change handling.

Tests: Python's tests ported (gates, archive with WAV bytes compared against Python's, history, settings, controller, mic stream, hotkeys, readiness, paste with a fake pasteboard). Then by hand in T3 Code, Chrome and WhatsApp: no text box focused, sleep and wake, Yeti unplugged, quick double taps, a 60 s dictation.

### Phase 2: draw while dictating (about 2,000 lines)

The mouse tap and ink tracker with its edge cases (owed mouse-up expiring after 5 s, a drag started before key-down belongs to the app, a fast re-press resumes, forget the button after a tap timeout, never leave the mouse stuck). Click-through ink panels per display, kept out of captures. `screencapture -x -o -l` as now, one shot per window, Core Graphics compositing, 1568 px long edge, and 256-colour PNGs from a small quantiser and PNG writer on the system zlib (libimagequant is GPL). `[n]` markers from whisper.cpp's token timestamps, only when there are marks. Text then images, 0.35 s apart. Tests: Python's drawing tests ported, golden images, markers checked against your saved marked dictations.

### Phase 3: the rest (about 1,200 lines)

Settings and history windows, a first-run permissions window, audio written to a `.wav.tmp` while you talk so a crash keeps it (the rest of #7), and checks on long dictations. Then delete the Python, Windows and install files.

### Phase 4: optional short-clip vote (about 600 lines plus engines)

Off by default, clips of 3 s or less only.

## Memory and latency

| | Memory | Latency |
|---|---|---|
| Today | 2.3 GB (1.9 GB this morning) | key-up to paste about 0.3 s on short clips |
| Phase 1 | 1.2 GB, ceiling 1.3 GB, flat after 100 dictations | final pass on clips up to 3 s: median 260 ms, p90 400 ms. Cmd+V within 20 ms after, plus one encoder step if a preview was running. Mic running within 20 ms of key-down |
| Phases 2 and 3 | same at rest, under 1.5 GB while compositing | word timings under 50 ms extra, only with marks |
| Phase 4, vote on | about 5.6 GB | set once the engine research lands |

Previews share the whisper context, so they cost GPU time but no memory.

## Engine interface for the vote

```swift
protocol SpeechEngine: AnyObject {
  var id: String { get }
  func load() throws   // own thread, under a watchdog
  func transcribe(_ audio: [Float], _ options: TranscribeOptions) throws -> Transcript
  func cancel()        // best effort
  func unload()
}
// Transcript: text, segments with times, no-speech prob, avg logprob, word timings
```

A decider sits after the gates: `Single(whisper)` now, later `ShortClipVote(primary, second, referee)`. Primary and second run together. If their words match (lower case, no punctuation or fillers), keep the primary. If not, run the referee and keep whichever is fewer word edits from it, primary on a tie, as `real/score_vote.py` does. The loop guard and corrections run on the winner.

From the engine research I'd need: the runtime and whether it can share a process with whisper.cpp's ggml (two copies may clash, meaning a helper process), memory, short-clip latency alone and next to whisper.cpp, how Qwen3-ASR takes the word list, cancelling, licence and download size. Worth checking first: the b5454 xcframework already exports a Parakeet API (`parakeet.h`, 68 functions).

## Risks

- whisper.cpp's tokeniser may split the word list differently. Caught in 1a.
- Core Audio's resampler may differ slightly from today's. Rerun the benchmark on a week of native recordings.
- Metal or Core Audio may still hang after wake. Watchdogs cover it, and restart-on-wake stays as a setting.
- `[n]` markers may land slightly differently with whisper.cpp's timings.
- A clipboard privacy prompt on macOS 26.

## Phase 1a result (24 October 2026)

Done. The CLI typed exactly the benchmark's whisper.cpp text on all 174 labelled clips and all 223 clips in the 20 to 23 October batch, raw and through the full pipeline, so the `vt-native` gate is met. `whisper_tokenize` splits Claude, Tailscale, Vercel and Parakeet differently from mlx-whisper and changed 8 and 11 of those texts ("Claudco terminals"), so the app uses its own tiktoken-style tokenizer, which gives mlx-whisper's 55 IDs. Short clips take a median of about 220 ms; memory is 1,119 MB and stays flat.

## Phase 1b to 1d result (24 October 2026)

Built and tested against fakes; not yet run on the Mac itself, which waits for Mike (see "Still to check by hand" below). About 9,400 lines of Swift on top of 1a: 6,500 of app and 2,900 of tests, after fixing what two reviews (Opus and Codex) found before the first run: Core Audio hangs that could wedge the app, a stream that delivers nothing, a denied clipboard read wiping the clipboard, a near-silence gate with too little margin, switching races, the build script, `restart`'s pid check, restart loops and logs, and two git-ignored fixtures.

- **App shell.** One executable: the menu bar app when its bundle is launched (by launchd or Launch Services), the command line otherwise. `scripts/build-app.sh` builds, signs whisper.framework and the app with the Apple Development identity (never ad hoc), checks the designated requirement is tied to the bundle id and certificate name, installs to `~/Applications`, puts the model in place against its SHA-256, writes the LaunchAgent and links the CLI. It works out which app is in use from `launchctl print-disabled` for both agents, not from whether native is running, so rebuilding after Quit doesn't leave both disabled. `--test-build DIR` does an ad hoc build into a folder for testing only; that's the only mode that has been run. The menu has status, microphone, a pause toggle, permissions, the log, Switch to Python and Quit. A permissions window covers Accessibility, Input Monitoring, Microphone and macOS 26's "Paste from other apps", with buttons that ask and open the right pane; the tap retries every 2 s until it's allowed. `native-status.json` says what the app is doing. The log rotates while running (past 1 MB it keeps the last 2,000 lines), isn't copied to `native-launchd.log` any more, and that file is trimmed in place at launch.
- **Only launchd's copy dictates.** A copy opened by hand while Python is in use only shows the permissions window and Switch to Voice Type Native: it never takes the lock, never polls for it, doesn't write the status file, and quits once launchd's copy has the lock. Opened by hand while native is in use, it starts launchd's copy and quits. launchd's copy doesn't take the lock while Python's agent is still enabled and launchd is running Python or about to bring it back (`launchctl print` shows it running, or its last exit wasn't 0). This closes the gap where a hand-opened copy grabbed the lock while Python relaunched after a wake, so Python's new worker exited 0 as a duplicate and stayed dead.
- **Switching.** Neither direction kills a dictation it can see. `switch native` waits for Python to read idle on its control socket and pauses it straight from that reading (`toggle_enabled`, which makes voice-type.py ignore key-downs). Python's interface has no single "pause if idle", so a key-down could still slip in during that one socket round trip, and while paused its `ui_state` reads "disabled" whatever it's doing, so such a dictation would only show once released (`finalize_in_flight`). Then it disables Python's agent, checks again, boots it out, and stops a Python launchd didn't start (one run by hand or from Spotlight, found by the pid in the lock and `voice-type.py` in its command line) and checks the lock is free before starting native. `switch python` asks a running native app to hand over itself (SIGUSR2): its controller stops taking dictations on its own queue, finishes one that's running, disables its agent, lets go of the lock and starts Python. If it isn't running or doesn't answer, the command line does it, stopping whichever native process holds the lock. Both agents' plists are checked (valid, right label, the program exists) before anything changes, and if starting the other app fails, everything goes back the way it was, Python's pause included. A failed Switch to Python from the menu takes the lock back before turning the tap on again; if Python got the lock anyway, Python stays in charge and native quits. `restart` sends SIGUSR1 and the app exits 75 once idle; it checks the status file's pid really is Voice Type Native before signalling it.
- **Dictation.** The controller is one state machine on one queue (starting, idle, recording, finalising, stopping, needs model), driven by key events, first audio, timers and finished work. Ported with their tests: the hotkeys, MicStream, the capture buffer, readiness (30 s for the Yeti, the 0.35 s probe), the paste flow (snapshot, lazy offer, 2 s read wait, focus check, restore only if untouched, Funk and "On your clipboard"), the pill's timings and tick, the archive and history (byte for byte against files Python's own code wrote), the watchdogs (180 s load, max(30 s, 2x clip) finalisation, 2 s audio start and stop, 10 s wake warm-up, each exiting 75 after `sample` writes every thread's stack). Core Audio input is an AUHAL unit opened while idle and started on key-down, with a lock-free ring and AVAudioConverter at maximum quality to 16 kHz, which gives identical samples however the audio is split into blocks.
- **Core Audio hangs.** Every Core Audio call has the 2 s limit: the readiness probe's open, start, stop and close, and the idle-time open (`AudioUnitInitialize`) as well as start and stop. A unit whose call timed out is abandoned: kept for the life of the process and never stopped, closed or freed, and once anything has hung the recorder doesn't touch the microphone again. A hang in the probe restarts the process at once rather than retrying (each retry used to leak a stuck thread). After a wake or a broken stream, a microphone that's there but gives nothing for 45 s restarts it too; at startup it waits as long as it takes, as Python did, and a missing microphone never counts. A microphone check that hasn't reported for 30 s, or a controller queue that doesn't answer a ping for 30 s, also restarts it. A key hold of 0.5 s or more that produced no audio at all (AUHAL can start fine after a wake and never call back) is treated as a flatline: "No microphone audio" while held, then the microphone reconnects.
- **Restarts back off.** Exit-75 restarts are recorded in `native-restarts.json`. The first is immediate, then it waits 30 s, 2 min and 5 min, and after five in 30 minutes it stays up, says what failed in the menu, and leaves F12 and Right Control alone until Try Again (or `voice-type-native restart`, which the build script runs). Only the first two in the window write a thread dump. Ready for a minute clears the list.
- **Keys.** F12 and Right Control are swallowed while starting (as Python did, since its readiness notice started the tap, so a press shows why nothing records), ready, recording and finalising. While paused, with no model, backing off or given up, they still reach the controller but go through to the system as normal keys. The choice is made per press, so a release always goes the same way as its press.
- **Clipboard denied.** If macOS won't let the clipboard be read ("Paste from other apps" set to Deny, or Don't Allow on its prompt), the copy-out comes back empty or without its data. The paste flow now spots that before it touches the clipboard, never puts back a copy it knows is incomplete, and leaves the dictated text on the clipboard instead of wiping it. The text has to go on the clipboard to be pasted at all, so the old contents are lost either way; leaving the words is the least bad option. The pill says so once per run ("Pasted. Allow Paste from other apps to keep your clipboard"), and the log and permissions window say how to allow it.
- **1d.** A live preview every 0.5 s once there's 0.8 s of audio (logged as one line per dictation, not one per pass), through the same inference thread: finals go first, key-up drops a waiting preview and aborts a running one through whisper.cpp's abort callback (measured: it stops after the encoder step that's running, about 0.2 s), and no preview starts until that dictation's final pass is done. Wake (the notification, or a wall-clock gap over 30 s) rebuilds audio, reruns readiness and does one silent warm-up under a 10 s watchdog, after the dictation if one is running. A flatline capture reconnects the microphone the same way instead of restarting. Device changes are debounced; losing the chosen microphone or the preferred one coming back reruns readiness, anything else reopens the stream at the next key-down.
- **The "Thank you." gate.** New in VoiceTypeCore, and speech-aware: a clip of 1 s or more whose peak stays under 0.008 still goes to Whisper, and is dropped only if what Whisper typed is one of its silence phrases ("Thank you.", "Thanks for watching!", "you" and a few more, once or repeated) or is mostly not Latin letters (punctuation, "C Надо"). Over all 1,865 recordings saved from 14 to 24 October, the 7 clips of 1 s or more that peaked under 0.005 were all silence (1.4 to 11.2 s, whisper.cpp typed "Thank you." for all of them and Python typed "Thank you.", "!", "C Надо" or a "Flare Flare..." loop), and the quietest real dictation of 1 s or more peaked at 0.0138 ("Sure.", 1.1 s; 0.0126 at any length). That margin is under 5 dB: with the Yeti 6 dB quieter, 6 of the 1,826 saved dictations would fall under the level, 21 at 8 dB and 58 at 10 dB, which a level-only gate would have dropped and this one types. Previews use the same check. A test runs it over those 1,865 levels, at the recorded gain and 6, 8 and 10 dB lower. The parity run (174/174 and 223/223 raw) was before this change; the pipeline should still differ from the benchmark only on the three "Thank you." clips 1a found, since whisper.cpp typed "Thank you." for them, but that hasn't been rerun.
- **Engine.** Unchanged for finals: the abort callback is only set for previews, and a test checks a flag that's never set gives the same text and token probabilities.

Differences from Python, on purpose: no control socket (the status file and CLI replace it, with SIGUSR1 to restart and SIGUSR2 to hand over to Python); a fallback microphone is looked up again at every key-down, and the Yeti coming back is noticed without a restart; settings.json is reread when it changes; previews hide Whisper's silence phrases on near-silent audio so they don't show "Thank you."; the hotkeys pass through while paused, with no model or after giving up; exit-75 restarts back off and stop; a denied clipboard read leaves the dictated text on the clipboard; the formatter, hybrid, stabilized and precompute modes, the history import from the old log, and the Windows code aren't ported.

Still to check by hand, with Mike there: the first signing's keychain prompt; the permission grants from the hand-opened window-only copy, and that it closes itself once native takes over; whether macOS 26 asks before Voice Type Native reads the clipboard (the status file and permissions window show `accessBehavior`), and what a denied read really returns (types with no data count as denied, and an empty copy is only put back when reads are always allowed, so either way the clipboard isn't wiped); the tap swallowing F12 and Right Control but not Left Control, and passing them through while paused; the orange dot only while the key is down; AUHAL capture on the Yeti and the MacBook microphone; paste into T3 Code, Chrome and WhatsApp, with no text box focused; sleep and wake; the Yeti unplugged and plugged back in; quick double taps; a 60 s dictation; switching both ways, including `switch python` from the command line while native is mid-dictation, and Python's pause (its control socket's `toggle_enabled`); memory after 100 dictations.

## Decided (Mike, 24 October 2026)

1. Switch to native at the end of phase 1, without drawing. Mike flips back to Python from the menu when he wants to draw, and phase 2 follows straight after.
2. The formatter and the hybrid, stabilized and precompute modes are dropped.
3. The Swift code lives in `native/` in this repo.
4. Python gets deleted after two weeks of native as the daily driver with no lost dictations and the benchmark within noise.
5. Still open: how much extra short-clip delay the vote is worth. Decide in phase 4, with measured numbers.

## Vote engines (research, 24 October 2026)

From `~/dev/me/voice-type-benchmark/native-vote-2026-10-24/REPORT.md`:

- Parakeet: FluidAudio (CoreML) v3 `.int8V2` builds and runs, about 40 ms on short clips. In the vote over the 173 clips it gave 16 known mistakes plus 2 uncalled texts, against 16 before. Also try the `parakeet.h` API in the whisper.cpp xcframework first, since it would share the ggml runtime.
- Qwen3-ASR: MLX Audio Swift supports the same 8-bit weights and the word list as `context` (append a newline after the list to match Python), but wasn't built (missing Metal Toolchain). Fallback: a Python helper alive only while the vote is on.
- Memory with the vote on: roughly 4.3 to 4.5 GB steady, 5.3 to 5.5 GB at Qwen's peak (estimated, not measured together).
