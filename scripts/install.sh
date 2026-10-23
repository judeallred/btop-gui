#!/usr/bin/env bash
# Builds and installs No Beachballs into /Applications (or ~/Applications), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy gracefully so it resumes anything it paused.
# (NoBeachballs is the executable name used by builds before 0.1.1.)
for name in nobeachballs NoBeachballs; do
  if pgrep -xq "$name"; then
    pkill -TERM -x "$name" || true
    for _ in $(seq 1 20); do pgrep -xq "$name" || break; sleep 0.25; done
  fi
done

rm -rf "$DEST/No Beachballs.app" "$DEST/NoBeachballs.app"
cp -R "build/No Beachballs.app" "$DEST/"
open "$DEST/No Beachballs.app"
echo "Installed to $DEST/No Beachballs.app"
