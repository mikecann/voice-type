# Agent guidance for voice-type

This repo contains the standalone Python dictation tool for Windows and macOS.

## Working rules

- Keep source in this repo. `C:\dev\tools` holds generated shortcuts or large
  external binaries, never source. Do not commit `.exe` or `.dll` files.
- Use test-first development for non-trivial behaviour changes. Update affected
  expectations and rerun the relevant tests after implementation.
- Before committing, run `python3 -m unittest discover -s tests -v` with the
  dependencies from `requirements-test.txt`. Check shell syntax with `bash -n`
  and parse every `.ps1` using PowerShell's `Language.Parser.ParseFile`.
- Smoke-test the real worker on its target OS when permissions and hardware
  are available. Otherwise record that limitation, do not claim a live pass.
- Windows GUI shortcuts must use `voice-type.vbs` and `wscript.exe`, with window
  style 0. Do not launch PowerShell directly from a taskbar shortcut.
- Keep `.bat` files ASCII. Generate them with `-Encoding ASCII` in PowerShell.
- `deps.ps1` must be self-contained and idempotent, check Python imports before
  installing with `python -m pip`, and show clear output. `install.ps1` runs it
  unless `-SkipDeps` is passed. Dependencies must not require API keys.
- Rerun `install.ps1` after changing shortcut registration, or `install.sh`
  after changing macOS setup. Windows shortcuts point to live source.
- Never overwrite existing user settings during install. The tracked example
  seeds new installs only. Runtime settings, history and logs stay out of Git.
- Preserve the macOS bundle/signing/LaunchAgent identity
  `com.mikerosoft.voice-type`; it protects existing permission grants.
- Keep README prose plain, friendly, and free of em dashes or en dashes.
- Start any PR description with `## Why` and explain why the change matters.

## voice-type specifics


Push-to-talk voice transcription tool. Hold Right Ctrl to record, release to transcribe and inject text into the active window.

### Dev workflow

After any code change to `voice-type.py`, restart with:

```
# From this repo root
restart.bat
```

`restart.bat` kills all existing instances then relaunches via `voice-type.vbs`.
Always use this - never launch `voice-type.py` directly with `Start-Process` or
`python`, as that bypasses the kill step and leaves multiple instances running.

After restarting, confirm a clean startup:
```powershell
Get-Content voice-type.log | Select-Object -Last 5
```

To verify exactly one instance is running:
```powershell
cmd /c "tasklist /FO CSV" | ConvertFrom-Csv | Where-Object { $_."Image Name" -like "*python*" }
```

**Rules:**
- Always kill all instances before launching a new one. Never leave multiple instances running.
- Always launch via `restart.bat` or `voice-type.vbs` - never directly with `Start-Process python ...`.
- After launching, tail the log to confirm a clean startup.
- On macOS, `setup_mac.sh` must install `~/Applications/Voice Type.app` via
  `install-spotlight-app.sh`; the app is the Spotlight entry point for opening
  settings. Building only `.venv/bin/Voice Type` is not sufficient for Spotlight.


### macOS development

Run `bash voice-type-mac.sh` to stage source and restart the installed worker.
Use `bash voice-type-mac.sh status` and tail
`~/Library/Logs/Voice Type/voice-type.log` to verify readiness. Do not run a
second worker directly. Setup and launch tests use temporary directories and
fake desktop commands. Native Spotlight packaging is opt-in via
`VOICE_TYPE_TEST_NATIVE_APP=1` and requires macOS desktop tooling.
