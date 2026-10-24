# Voice Type Native

The native Swift rewrite of Voice Type, planned in [PLAN.md](PLAN.md). This is phase 1a: the dictation pipeline and a command-line tool, with no app, hotkey or microphone yet. It runs whisper.cpp large-v3-turbo q8_0 on Metal and decodes exactly as the benchmark's whispercpp-bench does, so its text can be checked against the benchmark before anything gets built on top of it.

## Building

You need Xcode 27 on an Apple Silicon Mac running macOS 26.

```
cd native
swift build -c release
swift test
```

The first build downloads ggml-org's whisper.cpp xcframework (release b5454, about 66 MB) into `.build`. Package.swift pins its checksum, so nothing binary lives in git.

`swift test` runs the pure logic tests on their own. The tests that need the model skip themselves unless it's at the default path below or you point at it:

```
VOICE_TYPE_TEST_MODEL=/path/to/ggml-large-v3-turbo-q8_0.bin swift test
```

## The model

The tool looks for `~/Library/Application Support/Voice Type/models/ggml-large-v3-turbo-q8_0.bin`. Until the app puts one there, pass `--model` with the copy in the benchmark folder, for example `~/dev/me/voice-type-benchmark/models/whispercpp/ggml-large-v3-turbo-q8_0.bin`.

## Running it

None of these commands touch the keyboard tap, the microphone or the Python app's lock, so they're safe to run while Voice Type is dictating. settings.json and the recordings are only ever read.

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

By default each command runs the whole pipeline the way voice-type.py does it: the flatline and near-silence gates, the 0.3 s minimum, Whisper, the repetition loop guard, then your corrections. `--raw` runs Whisper alone (still with the word list prompt, since that's part of how it decodes). The word list and corrections come from `settings.json` in `~/Library/Application Support/Voice Type`, or wherever `$VOICE_TYPE_DATA_DIR` points, and `--settings` can point at another file.

`serve` reads one JSON request per line, `{"id": ..., "path": FILE}`, where FILE is raw 16 kHz float32 (what the benchmark writes) or a WAV. It answers with the text, Whisper's time in `ms`, the segments, and the gate's status and levels. If a request carries `prompt_tokens` they're used as given; leave them out to test the native tokenizer, which is what a benchmark key for this should do.

Recordings are 16 kHz mono float WAVs, so nothing is resampled. Any other sample rate is refused rather than resampled differently from the benchmark.

## Checking it against the benchmark

`scripts/parity.py` runs the labelled short clips and the 2026-10-20 review batch through `serve` and compares the text with the benchmark's saved whisper.cpp output:

```
python3 scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH --raw
python3 scripts/parity.py ~/dev/me/voice-type-benchmark /tmp/parity --model PATH
```

It only reads the benchmark folder. Results go to the folder you give it, as JSON from clip id to text.

## Layout

- `Sources/VoiceTypeCore`: everything that decides the text apart from the model: settings, the word list prompt and a tokenizer that matches mlx-whisper's, the gates, the loop guard, corrections, WAV reading and the pipeline. No whisper or AppKit, so it's tested on its own.
- `Sources/VoiceTypeWhisper`: the whisper.cpp engine, the only code that calls whisper.cpp.
- `Sources/voice-type-native`: the command-line tool.
- `Tests`: the Python tests for the gates, loop guard, word list and corrections, ported with the same cases, plus tests for the rest.

Why the tokenizer is our own: whisper.cpp's `whisper_tokenize` picks the longest matching token at each step, while Whisper was trained on tiktoken's byte-pair encoding. They split Claude, Tailscale, Vercel and Parakeet differently, so the prompt wouldn't be the one the benchmark measured. `WhisperBPETokenizer` repeats tiktoken's rules using the ranks in the model file and gives the same 55 tokens as mlx-whisper for today's word list.
