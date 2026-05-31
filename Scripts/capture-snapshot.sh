#!/bin/bash
# Capture a render snapshot to a PNG using the real SpriteKitRenderer, off-screen, headless.
# Proves the renderer can pause a sim at a tick and rasterize (part of) the map to a file.
#
# Usage:  Scripts/capture-snapshot.sh [extra rendercap args...]
# Examples:
#   Scripts/capture-snapshot.sh                                  # first scenario, tick 0, whole map
#   Scripts/capture-snapshot.sh --tick 120                       # advance 120 ticks first
#   Scripts/capture-snapshot.sh --scenario SCENA001.INI --rect 28,28,16,16   # a 16×16-tile crop
#   Scripts/capture-snapshot.sh --tick 200 --fog --out /tmp/foggy.png
#
# Writes to Code/.build/snapshot.png by default (override with --out).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CODE="$REPO/Code"
INSTALL="$REPO/Repositories/patched_107_unofficial"
OUT_DEFAULT="$CODE/.build/snapshot.png"

cd "$CODE"
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR"

# Default --out if the caller didn't pass one.
HAS_OUT=false
for a in "$@"; do [ "$a" = "--out" ] && HAS_OUT=true; done
EXTRA=("$@")
$HAS_OUT || EXTRA+=(--out "$OUT_DEFAULT")

echo "== building rendercap =="
xcrun swift build --disable-sandbox --product rendercap 2>&1 | tail -3

echo "== capturing (install: $INSTALL) =="
xcrun swift run --disable-sandbox rendercap "$INSTALL" "${EXTRA[@]}"
