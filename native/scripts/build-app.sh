#!/usr/bin/env bash
# Builds Voice Type Native.app, signs it, and installs it with its LaunchAgent.
#
#   native/scripts/build-app.sh
#       Builds, signs with the Apple Development identity, installs to ~/Applications,
#       copies the speech model into place if it's missing, writes the LaunchAgent, and
#       links voice-type-native into ~/.local/bin. Then it makes sure the LaunchAgent is
#       enabled and running: a running app restarts into the new build once it's idle, and
#       one that isn't running (or has never been installed) is started.
#
#   native/scripts/build-app.sh --test-build DIR
#       FOR TESTING ONLY. Builds and ad hoc signs the app into DIR and writes the LaunchAgent
#       there for inspection. It never touches the keychain, ~/Applications,
#       ~/Library/LaunchAgents, Voice Type's data folder or launchctl. Never install what
#       it makes: an ad hoc signature pins macOS's permission grants to that exact binary, so
#       every rebuild would lose Accessibility, Input Monitoring and the microphone.
#
# Signing: the designated requirement of an Apple Development signature is the bundle id
# plus the certificate's name, which every rebuild matches, so permissions survive rebuilds.
# The script never falls back to ad hoc outside --test-build, and checks the requirement
# after signing. No sandbox and no hardened runtime. The first signing shows a keychain
# prompt for the identity's key: choose Always Allow.

set -euo pipefail

IDENTITY="Apple Development: Michael Cann (4BAC88BW64)"
BUNDLE_ID="com.mikerosoft.voice-type-native"
APP_NAME="Voice Type Native"
LABEL="com.mikerosoft.voice-type-native"
MODEL_NAME="ggml-large-v3-turbo-q8_0.bin"
# whisper.cpp's large-v3-turbo q8_0, the file the benchmark measured.
MODEL_SHA256="317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
BENCHMARK_MODEL="${VOICE_TYPE_MODEL_SOURCE:-$HOME/dev/me/voice-type-benchmark/models/whispercpp/$MODEL_NAME}"

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"

mode="install"
out_dir=""
case "${1:-}" in
  "") ;;
  --test-build)
    mode="test"
    out_dir="${2:?--test-build needs a folder}"
    ;;
  -h|--help)
    sed -n '2,24p' "$0"
    exit 0
    ;;
  *)
    echo "usage: $0 [--test-build DIR]" >&2
    exit 2
    ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'build-app: %s\n' "$*" >&2; exit 1; }

version="0.1.0"
build_number="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
commit="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Fail before building if the identity isn't there, rather than signing ad hoc.
if [[ "$mode" == "install" ]]; then
  if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    die "the signing identity \"$IDENTITY\" isn't in the keychain. Not signing ad hoc, since that would lose the app's permissions on every rebuild."
  fi
fi

say "Building (release)..."
(cd "$NATIVE_DIR" && swift build -c release --product voice-type-native)
bin_dir="$(cd "$NATIVE_DIR" && swift build -c release --show-bin-path)"
[[ -x "$bin_dir/voice-type-native" ]] || die "no binary at $bin_dir/voice-type-native"
[[ -d "$bin_dir/whisper.framework" ]] || die "no whisper.framework next to the binary in $bin_dir"

if [[ "$mode" == "test" ]]; then
  mkdir -p "$out_dir"
  stage="$(cd "$out_dir" && pwd)"
else
  stage="$(mktemp -d "${TMPDIR:-/tmp}/voice-type-native-build.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
fi
app="$stage/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

# The icon is drawn in native/icons/voice-type-native.svg and rendered to the PNG next to it.
icon_png="$NATIVE_DIR/icons/voice-type-native.png"
[[ -f "$icon_png" ]] || die "no app icon at $icon_png"
iconset="$stage/voice-type-native.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/voice-type-native.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>voice-type-native</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>voice-type-native</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$build_number</string>
  <key>VoiceTypeCommit</key>
  <string>$commit</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <!-- A menu bar app: no Dock icon, no app menu. -->
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Voice Type Native listens while you hold F12 or Right Control, and turns what you say into text.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

cp "$bin_dir/voice-type-native" "$app/Contents/MacOS/voice-type-native"
# ditto keeps the framework's Versions symlinks.
ditto "$bin_dir/whisper.framework" "$app/Contents/Frameworks/whisper.framework"
# SwiftPM's binary looks for the framework next to itself; in the bundle it's in Frameworks.
if ! otool -l "$app/Contents/MacOS/voice-type-native" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/voice-type-native"
fi

if [[ "$mode" == "test" ]]; then
  say "TESTING ONLY: signing ad hoc. Don't install this build."
  codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/whisper.framework"
  codesign --force --sign - --timestamp=none "$app"
else
  say "Signing with $IDENTITY (the first time, macOS asks for the keychain: choose Always Allow)..."
  codesign --force --sign "$IDENTITY" --timestamp=none "$app/Contents/Frameworks/whisper.framework"
  codesign --force --sign "$IDENTITY" --timestamp=none "$app"
fi

codesign --verify --strict --deep "$app" || die "the signature doesn't verify"
# An implicit requirement prints as "# designated => ...", an embedded one without the "# ".
requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^# *designated => //p; s/^designated => //p')"
say "Designated requirement: $requirement"
if [[ "$mode" == "install" ]]; then
  [[ "$requirement" == *"identifier \"$BUNDLE_ID\""* ]] || die "the designated requirement doesn't name $BUNDLE_ID"
  [[ "$requirement" == *"certificate leaf[subject.CN] = \"$IDENTITY\""* ]] || die "the designated requirement isn't tied to \"$IDENTITY\""
  [[ "$requirement" != *cdhash* ]] || die "the designated requirement is pinned to a hash (an ad hoc signature), so permissions wouldn't survive a rebuild"
else
  [[ "$requirement" == *cdhash* ]] || die "expected an ad hoc (cdhash) requirement in a test build"
fi

if [[ "$mode" == "test" ]]; then
  "$app/Contents/MacOS/voice-type-native" launch-agent-plist "$HOME/Applications/$APP_NAME.app/Contents/MacOS/voice-type-native" > "$stage/$LABEL.plist"
  plutil -lint "$stage/$LABEL.plist" >/dev/null
  say "TESTING ONLY: built $app"
  say "TESTING ONLY: the LaunchAgent install would write is at $stage/$LABEL.plist"
  exit 0
fi

# --- Install -------------------------------------------------------------------------

data_dir="${VOICE_TYPE_DATA_DIR:-$HOME/Library/Application Support/Voice Type}"
agents_dir="$HOME/Library/LaunchAgents"
plist="$agents_dir/$LABEL.plist"
installed="$HOME/Applications/$APP_NAME.app"
executable="$installed/Contents/MacOS/voice-type-native"
domain="gui/$(id -u)"

mkdir -p "$HOME/Applications" "$agents_dir" "$HOME/Library/Logs/Voice Type"
# Swap whole bundles with renames, so a running copy keeps its own files until it restarts.
rm -rf "$HOME/Applications/.$APP_NAME.app.new" "$HOME/Applications/.$APP_NAME.app.old"
ditto "$app" "$HOME/Applications/.$APP_NAME.app.new"
if [[ -d "$installed" ]]; then mv "$installed" "$HOME/Applications/.$APP_NAME.app.old"; fi
mv "$HOME/Applications/.$APP_NAME.app.new" "$installed"
rm -rf "$HOME/Applications/.$APP_NAME.app.old"
# Tell Launch Services about the swapped bundle, or Finder and System Settings can keep
# showing the previous build's icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed" >/dev/null 2>&1 || true
say "Installed $installed"

model="$data_dir/models/$MODEL_NAME"
if [[ ! -f "$model" ]]; then
  mkdir -p "$data_dir/models"
  if [[ -f "$BENCHMARK_MODEL" ]]; then
    say "Copying the speech model from $BENCHMARK_MODEL..."
    cp "$BENCHMARK_MODEL" "$model.part"
  else
    say "Downloading the speech model (874 MB)..."
    curl -fL --retry 3 -o "$model.part" "$MODEL_URL"
  fi
  actual="$(shasum -a 256 "$model.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$MODEL_SHA256" ]]; then
    rm -f "$model.part"
    die "the model's SHA-256 is $actual, not $MODEL_SHA256"
  fi
  mv "$model.part" "$model"
  say "Model in place: $model"
fi

"$executable" launch-agent-plist "$executable" > "$plist.tmp"
plutil -lint "$plist.tmp" >/dev/null
mv "$plist.tmp" "$plist"
say "LaunchAgent: $plist"

if [[ -d "$HOME/.local/bin" ]]; then
  ln -sf "$executable" "$HOME/.local/bin/voice-type-native"
  say "Linked ~/.local/bin/voice-type-native"
fi

# The agent should always be enabled, so the app starts at login. Older builds disabled it
# to hand the hotkey to the Python version.
overrides="$(launchctl print-disabled "$domain" 2>/dev/null || true)"
# `"label" => disabled` on current macOS, `=> true` on older ones.
if grep -qF "\"$LABEL\" => disabled" <<<"$overrides" || grep -qF "\"$LABEL\" => true" <<<"$overrides"; then
  say "Enabling the LaunchAgent..."
  launchctl enable "$domain/$LABEL"
fi

# Read into a variable rather than piped into grep -q, which can kill launchctl with SIGPIPE
# and so fail the pipeline under pipefail even when the line is there.
if ! agent="$(launchctl print "$domain/$LABEL" 2>/dev/null)"; then
  say "Starting Voice Type Native..."
  launchctl bootstrap "$domain" "$plist"
elif grep -qF "state = running" <<<"$agent"; then
  say "Restarting Voice Type Native into the new build once it's idle..."
  "$executable" restart
else
  # Loaded but not running: quit from its menu, say.
  say "Starting Voice Type Native..."
  launchctl kickstart "$domain/$LABEL"
fi
say ""
say "Built and installed. Hold F12 or Right Control to dictate; \`voice-type-native status\` shows what it's doing."
