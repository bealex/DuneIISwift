#!/usr/bin/env bash
#
# Generate the behavioural-scenario golden fixtures from the OpenDUNE oracle.
#
# Self-contained + headless (no display needed): the oracle's --parity-scenario mode does a minimal init
# (pools + ICON.MAP + UNIT.EMC, no GFX), loads the shared SCEN<H><id>.INI (terrain from [MAP] Seed ->
# Map_CreateLandscape), places units on the map, points the viewport at the region (so scripts run
# full-speed), replays the simulated player command stream (--parity-cmd=<move|attack>,<unitIndex>,<tile>),
# ticks GameLoop for --parity-ticks=N, and dumps one JSON line of per-unit state per tick — units
# actually move. The Swift ScenariosTests/ScenarioGoldenTests reproduces the same and compares per tick
# (raise its `comparedTicks` as our movement/combat natives land).
#
# Usage:   Scripts/gen-scenario-goldens.sh [INSTALL_DIR]
#   INSTALL_DIR defaults to Repositories/patched_107_unofficial. TICKS env var overrides the tick count.
#
# Finding a unit's index for a --parity-cmd: run a scenario once with no commands and read the dump —
# each unit line has its "index". (For one Harkonnen tank it's 22 = the tank pool band's first slot.)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORACLE="$REPO/Repositories/OpenDUNE"
FIX="$REPO/Code/Tests/ScenariosTests/Fixtures"
DATADIR="$REPO/Code/.build/scengen"
TICKS="${TICKS:-400}"

# Args: [INSTALL_DIR] [--only <name>]. `--only` regenerates just one scenario (skip the other 5 while
# iterating on one); the first non-flag positional is the install dir.
ONLY=""; INSTALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)   ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#--only=}"; shift ;;
    *)        INSTALL="$1"; shift ;;
  esac
done
INSTALL="${INSTALL:-$REPO/Repositories/patched_107_unofficial}"

[ -d "$INSTALL" ] || { echo "install dir not found: $INSTALL" >&2; exit 1; }

echo "Building the OpenDUNE oracle…"
"$REPO/Scripts/build-oracle.sh" >/dev/null || { echo "oracle build failed" >&2; exit 1; }

echo "Staging data dir ($DATADIR = install + scenario INIs)…"
rm -rf "$DATADIR"; mkdir -p "$DATADIR"
for f in "$INSTALL"/*; do ln -sf "$f" "$DATADIR/"; done

# run <name> <scenarioId> <iniFile> <ticks> <cmd...>
#   cmd = move|attack,<unitIndex>,<packedTile>  →  --parity-cmd
#         place,<cyIndex>,<objectType>,<tile>   →  --parity-place (build+place a structure on a CY)
run() {
  local name="$1" id="$2" ini="$3" ticks="$4"; shift 4
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && return 0
  cp "$FIX/$ini" "$DATADIR/$(printf 'SCENH%03d.INI' "$id")"
  local args=(--parity-scenario="$id" --parity-ticks="$ticks"
              --parity-data-dir="$DATADIR" --parity-dump="$FIX/$name-golden.jsonl"
              --parity-random-trace="$FIX/$name-r256.txt" --parity-lcg-trace="$FIX/$name-lcg.txt")
  local c; for c in "$@"; do
    if [[ "$c" == place,* ]]; then args+=(--parity-place="${c#place,}"); else args+=(--parity-cmd="$c"); fi
  done
  echo "  $name  (scenario $id, $ticks ticks, cmds: $*)"
  "$ORACLE/bin/opendune" "${args[@]}"
}

# ───────────────────────────────────────────────────────────────────────────────────────────
#  name       id   ini            ticks    commands (kind,unitIndex,packedTile)
# ───────────────────────────────────────────────────────────────────────────────────────────
run  moving       99   bootstrap.ini     "$TICKS"  move,22,2600
run  move-trike   98   move-trike.ini    "$TICKS"  move,22,1040
run  attack-close 97   attack-close.ini  "$TICKS"  attack,22,1041
run  guard        96   guard.ini         "$TICKS"  move,23,1100
run  attack-rocket 95   attack-rocket.ini "$TICKS"  attack,22,1045
run  attack-structure 94 attack-structure.ini "$TICKS" attack,22,1042
run  trooper      92   trooper.ini       "$TICKS"  move,22,1040
run  economy      93   economy.ini       60
run  teams        91   teams.ini         "$TICKS"
run  missile-duel 90   missile-duel.ini  "$TICKS"  attack,22,1045  attack,23,1040
run  wall-destruction 89 wall-destruction.ini "$TICKS" attack,22,1042
run  slab-indestructible 88 slab-indestructible.ini "$TICKS" attack,22,1042
# refinery-harvester: a CY builds + places two refineries on a concrete pad; EACH placement spawns its own
# ferried harvester (viewport.c:210). Frame 0 only (0 ticks) — compares the CY + 2 refineries, the 2 spawned
# carryalls (positions prove the Unit_CreateWrapper spawn RNG aligned), and houses' unitCount==4 +
# harvestersIncoming==0. The in-transport harvesters are skipped by Unit_Find (both engines).
run  refinery-harvester 87 refinery-harvester.ini 0 place,0,12,1168 place,0,12,1296
# Multi-unit attack/guard match the deterministic prefix (setup + movement + the guard sitting); the
# Swift side gates `compared` before combat RNG (target acquisition / fire), which parity doesn't chase.
# attack-structure dumps structures + houses too (Scen_DumpState): a tank drains + destroys a windtrap.
# economy uses the [HOUSES] section to activate an Ordos base (windtrap+silo) — a per-tick HOUSE golden
# (credits/power/storage) validating House_CalculatePowerAndCredit + the credit clamp; 60 ticks (static).

# Tier-2a: the windtrap's (structure index 0) per-opcode decision trace for attack-structure (the
# SCENH094.INI staged by its `run` above). Diffed line-by-line by ScenariosTests/StructureTraceTests.
if [ -z "$ONLY" ] || [ "$ONLY" = "attack-structure" ]; then
  echo "  attack-structure-struct0-trace  (structure decision-trace)"
  "$ORACLE/bin/opendune" --parity-scenario=94 --parity-ticks="$TICKS" \
    --parity-data-dir="$DATADIR" --parity-dump="$DATADIR/_trace-dump.jsonl" \
    --parity-cmd=attack,22,1042 \
    --parity-script-trace="$FIX/attack-structure-struct0-trace.txt" --parity-script-structure=0
fi

echo
echo "Done — fixtures written under $FIX/."
echo "Now run the Swift golden:  cd Code && swift test --filter ScenarioGoldenTests"
echo "and raise \`comparedTicks\` in ScenarioGoldenTests as the per-tick behaviour is ported."
