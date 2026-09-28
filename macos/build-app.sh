#!/usr/bin/env bash
# Builds DipAgent.app (release) into ./build – works with Xcode or just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DipAgent.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/DipAgent"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DipAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # localizations (en = source strings, de = translations)

# App icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Resources/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature (needed for notifications / launch at login)
codesign --force --deep --sign - "$APP"

echo "✅ Built: $(pwd)/$APP"
echo "   Install: cp -R \"$APP\" /Applications/"
