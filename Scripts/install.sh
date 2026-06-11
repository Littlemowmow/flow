#!/bin/zsh
# Flow installer: clone, build, install. Requires Xcode 26+ on Apple Silicon.
#   curl -fsSL https://raw.githubusercontent.com/Littlemowmow/flow/main/Scripts/install.sh | zsh
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ Flow requires Apple Silicon." >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "❌ Xcode (or Command Line Tools) required. Install Xcode 26+ from the App Store." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Cloning Flow…"
git clone --depth 1 https://github.com/Littlemowmow/flow.git "$TMP/flow"
echo "Building (first build takes a minute)…"
"$TMP/flow/Scripts/bundle.sh"
rm -rf /Applications/Flow.app
cp -R "$TMP/flow/build/Flow.app" /Applications/

echo "Setting fn key to 'Do Nothing' so it doesn't fight the hotkey…"
defaults write com.apple.HIToolbox AppleFnUsageType -int 0

open /Applications/Flow.app
echo ""
echo "✅ Flow installed and launched."
echo "→ Grant Accessibility, Input Monitoring, and Microphone when prompted"
echo "  (or via the ⚠️ item in Flow's menu bar menu)."
echo "→ Then hold fn and speak. fn+space for hands-free."
