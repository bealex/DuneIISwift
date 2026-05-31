#!/usr/bin/env bash
#
# Regenerate the render-golden reference PNGs (Code/Tests/RenderGoldenTests/Fixtures/<name>.png).
#
# Each reference is captured by the RenderGoldenTests suite itself in "record" mode (DUNEII_RENDER_RECORD=1):
# it runs a scenario to a tick through the real simulation, captures a tile-space region through the real
# SpriteKitRenderer (off-screen, GPU-backed), and writes the PNG instead of diffing it. Running the same
# suite without the env var then diffs a fresh capture pixel-exact against these references.
#
# Capture is GPU-backed, so this needs a real Mac with an off-screen graphics context (the original 1.07
# install present at Repositories/patched_107_unofficial). On a no-GPU/no-install box the cases short-circuit
# and nothing is written.
#
# Usage:   Scripts/gen-render-goldens.sh
#
# Add/adjust a case in Tests/RenderGoldenTests/RenderGoldenTests.swift (the `cases` table), then re-run this
# to (re)capture its reference. Review the new/changed PNGs visually before committing.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CODE="$REPO/Code"
FIX="$CODE/Tests/RenderGoldenTests/Fixtures"

cd "$CODE"
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR"

echo "Recording render-golden references → $FIX"
DUNEII_RENDER_RECORD=1 xcrun swift test --disable-sandbox --filter RenderGoldenTests 2>&1 \
  | grep -iE "recorded|skipped|error:" || true

echo "Done. Review the PNGs, then re-run without the env var to confirm they diff clean:"
echo "  Scripts/check.sh --filter RenderGoldenTests"
