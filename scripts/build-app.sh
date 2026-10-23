#!/usr/bin/env bash
# Builds build/btop-gui.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product BtopGUI
BIN="$(swift build -c release --show-bin-path)/BtopGUI"
APP="build/btop-gui.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BtopGUI"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
