#!/usr/bin/env bash
# Builds and installs NoBeachballs into /Applications (or ~/Applications), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy gracefully so it resumes anything it paused.
if pgrep -xq NoBeachballs; then
  pkill -TERM -x NoBeachballs || true
  for _ in $(seq 1 20); do pgrep -xq NoBeachballs || break; sleep 0.25; done
fi

rm -rf "$DEST/NoBeachballs.app"
cp -R build/NoBeachballs.app "$DEST/"
open "$DEST/NoBeachballs.app"
echo "Installed to $DEST/NoBeachballs.app"
