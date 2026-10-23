#!/usr/bin/env bash
# Prints the app version from Resources/Info.plist.
set -euo pipefail
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(dirname "$0")/../Resources/Info.plist"
