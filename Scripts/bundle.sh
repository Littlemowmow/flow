#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Flow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Flow "$APP/Contents/MacOS/Flow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "✅ $APP"
echo "Install: cp -R $APP /Applications/"
