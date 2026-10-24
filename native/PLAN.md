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
