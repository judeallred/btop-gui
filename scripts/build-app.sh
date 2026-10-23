#!/usr/bin/env bash
# Builds "build/No Beachballs.app" (release).
#
#   UNIVERSAL=1           build for Apple silicon and Intel (default: this Mac's architecture)
#   CODESIGN_IDENTITY=…   sign with this identity and the hardened runtime, ready to notarize
#                         (default: ad-hoc signature, fine for local use)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [ "${UNIVERSAL:-}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release --product nobeachballs ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/nobeachballs"
APP="build/No Beachballs.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/nobeachballs"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/nobeachballs"))"
