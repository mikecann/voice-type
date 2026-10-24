# Agent guidance for voice-type

This repo is Voice Type, push-to-talk dictation for the Mac. It's a Swift menu bar app called Voice Type Native, in `native/`, that runs whisper.cpp locally. [native/README.md](native/README.md) covers building, the data it keeps and the command line, and [native/PLAN.md](native/PLAN.md) has the design and its history. The original Python version was removed after commit 17e8220.

## Working rules

- Build and test in `native/` with `swift build` and `swift test`. Use test-first development for non-trivial behaviour changes, and rerun the tests after implementation. The whisper tests skip themselves unless the model is installed or `VOICE_TYPE_TEST_MODEL` points at it. If a timing test fails on a busy machine, rerun it once before treating it as real.
- Decisions go in `Sources/VoiceTypeCore`, behind its protocols, tested against fakes. Keep `Sources/VoiceTypeMac` thin. Nothing in `swift test` may open the keyboard or mouse tap, the microphone or the pasteboard, take a screenshot or run launchctl.
- Never change the bundle id `com.mikerosoft.voice-type-native`, the signing identity `Apple Development: Michael Cann (4BAC88BW64)` or the LaunchAgent label `com.mikerosoft.voice-type-native`. macOS ties the app's Accessibility, Input Monitoring, Microphone and Screen Recording grants to the bundle id and certificate, so changing either means granting everything again. Keep the app name "Voice Type Native" and the `voice-type-native` command too.
- Never install a `--test-build`. `native/scripts/build-app.sh --test-build DIR` signs ad hoc into DIR for checking a build, and an ad hoc signature would lose every permission grant.
- Keep the data formats. settings.json, `transcription-history.jsonl`, the recordings archive, `native-status.json` and `screenshots/` use the formats the Python version wrote, and Mike's existing data has to keep working. Don't rename the format code (`PythonJSONWriter`, `PythonText`, `PythonTime`, `OrderedJSON`).
- The fixtures under `native/Tests/VoiceTypeCoreTests/Fixtures` were written by the Python version's own code. To regenerate them, check out commit 17e8220.
- Recordings, transcription history and Mike's screen captures never go in the repo, not even as test fixtures.
- Smoke-test the installed app on the Mac when permissions and hardware are available. Otherwise say so, and don't claim a live pass.
- Keep README prose plain, friendly, and free of em dashes or en dashes.
- Start any PR description with `## Why` and explain why the change matters.

## Dev workflow

After a code change, run `native/scripts/build-app.sh` from the repo root. It builds, signs, installs and restarts the app into the new build once it's idle. Then check it came back:

```sh
voice-type-native status
tail -n 20 "$HOME/Library/Logs/Voice Type/voice-type-native.log"
```

Don't start a second copy by hand to test it. Only the copy launchd starts dictates, and `voice-type-native restart` restarts it (or starts it if it isn't running).
