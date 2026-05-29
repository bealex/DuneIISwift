#!/usr/bin/env bash
#
# Generate the behavioural-scenario golden fixtures from the OpenDUNE oracle.
#
# RUN THIS OUTSIDE THE SANDBOX (a normal macOS terminal). The oracle's real scenario run
# (Game_LoadScenario + GameLoop) needs the full game init — GFX/sprites — which does not run in the
# agent's headless sandbox. Each scenario:
#   1. loads the shared SCEN<H><id>.INI via the real scenario path (so terrain comes from [MAP] Seed ->
#      Map_CreateLandscape, and units are placed + put on the map by Game_Prepare),
#   2. replays the simulated player command stream (--parity-cmd=<move|attack>,<unitIndex>,<tile>),
#   3. ticks GameLoop for --parity-ticks=N, dumping one JSON line of per-unit state per tick.
# The Swift ScenariosTests/ScenarioGoldenTests reproduces the same and compares per tick (raise its
# `comparedTicks` as our movement/combat natives land).
#
# Usage:   Scripts/gen-scenario-goldens.sh [INSTALL_DIR]
#   INSTALL_DIR defaults to Repositories/patched_107_unofficial. TICKS env var overrides the tick count.
#
# Finding a unit's index for a --parity-cmd: run a scenario once with no commands and read the dump —
# each unit line has its "index". (For one Harkonnen tank it's 22 = the tank pool band's first slot.)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${1:-$REPO/Repositories/patched_107_unofficial}"
ORACLE="$REPO/Repositories/OpenDUNE"
FIX="$REPO/Code/Tests/ScenariosTests/Fixtures"
DATADIR="$REPO/Code/.build/scengen"
TICKS="${TICKS:-120}"

[ -d "$INSTALL" ] || { echo "install dir not found: $INSTALL" >&2; exit 1; }

echo "Building the OpenDUNE oracle…"
( cd "$ORACLE" && PATH="$PWD/.shim:$PATH" make -j4 >/dev/null )

echo "Staging data dir ($DATADIR = install + scenario INIs)…"
rm -rf "$DATADIR"; mkdir -p "$DATADIR"
for f in "$INSTALL"/*; do ln -sf "$f" "$DATADIR/"; done

# run <name> <scenarioId> <iniFile> <ticks> <cmd...>   (cmd = move|attack,<unitIndex>,<packedTile>)
run() {
  local name="$1" id="$2" ini="$3" ticks="$4"; shift 4
  cp "$FIX/$ini" "$DATADIR/$(printf 'SCENH%03d.INI' "$id")"
  local args=(--parity-scenario-run="$id" --parity-ticks="$ticks"
              --parity-data-dir="$DATADIR" --parity-dump="$FIX/$name-golden.jsonl")
  local c; for c in "$@"; do args+=(--parity-cmd="$c"); done
  echo "  $name  (scenario $id, $ticks ticks, cmds: $*)"
  "$ORACLE/bin/opendune" "${args[@]}"
}

# ───────────────────────────────────────────────────────────────────────────────────────────
#  name       id   ini            ticks    commands (kind,unitIndex,packedTile)
# ───────────────────────────────────────────────────────────────────────────────────────────
run  moving    99   bootstrap.ini  "$TICKS"  move,22,2600
# Add scenarios here as their .INI + commands are defined (close/far attack, guarding, building).

echo
echo "Done — fixtures written under $FIX/."
echo "Now run the Swift golden:  cd Code && swift test --filter ScenarioGoldenTests"
echo "and raise \`comparedTicks\` in ScenarioGoldenTests as the per-tick behaviour is ported."
