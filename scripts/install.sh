#!/usr/bin/env bash
# Builds and installs btop-gui into /Applications (or ~/Applications), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy gracefully so it resumes anything it paused.
if pgrep -xq BtopGUI; then
  pkill -TERM -x BtopGUI || true
  for _ in $(seq 1 20); do pgrep -xq BtopGUI || break; sleep 0.25; done
fi

rm -rf "$DEST/btop-gui.app"
cp -R build/btop-gui.app "$DEST/"
open "$DEST/btop-gui.app"
echo "Installed to $DEST/btop-gui.app"
