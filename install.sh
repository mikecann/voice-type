#!/usr/bin/env bash
# Install the stable macOS runtime and make voice-type available on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: bash install.sh [target_bin_dir]"
  echo "Installs dependencies and ~/Applications/Voice Type.app, then links voice-type."
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: bash install.sh [target_bin_dir]" >&2
  exit 1
fi
DEST="$TARGET_DIR/voice-type"
if [[ -e "$DEST" && ! -L "$DEST" ]]; then
  echo "Refusing to replace an existing file: $DEST" >&2
  exit 1
fi
bash "$ROOT/setup_mac.sh"
mkdir -p "$TARGET_DIR"
ln -sfn "$ROOT/voice-type-mac.sh" "$DEST"
echo "Installed command: $DEST"
case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "Add this directory to PATH in ~/.zshrc: $TARGET_DIR" ;;
esac
echo "Launch or restart: voice-type"
echo "Open settings from Spotlight: Voice Type"
