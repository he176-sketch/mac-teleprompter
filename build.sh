#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/MacTeleprompter.app"
BIN="$APP/Contents/MacOS/MacTeleprompter"

# Prefer the installed full Xcode toolchain. The standalone Command Line Tools
# on this Mac ship a Swift compiler that does not match their AppKit SDK.
if [[ -d "/Applications/Xcode-16.2.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-16.2.app/Contents/Developer"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  "$ROOT/Sources/ScriptFollower.swift" \
  "$ROOT/Sources/TeleprompterApp.swift" \
  -o "$BIN"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
touch "$APP"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
