#!/usr/bin/env bash
#
# golden.sh — summarise a scenario golden JSONL as a per-tick timeline of *what changed* (instead of
# re-rolling a python one-liner each time a golden diverges). Prints only the ticks where the chosen
# summary changed, so a 400-line fixture collapses to the handful of interesting transitions.
#
# Usage:  Scripts/golden.sh <name> [both|units|structures]
#   e.g.  Scripts/golden.sh attack-structure structures   → the windtrap's hp/state over the run
#
# ⚠️  MAINTAIN alongside the other Scripts/.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:-}"
what="${2:-both}"
[ -n "$name" ] || { echo "usage: golden.sh <name> [both|units|structures]" >&2; exit 2; }
f="$REPO/Code/Tests/ScenariosTests/Fixtures/${name}-golden.jsonl"
[ -f "$f" ] || { echo "no golden: $f" >&2; exit 1; }

python3 - "$f" "$what" <<'PY'
import json, sys
path, what = sys.argv[1], sys.argv[2]
prev = None
for line in open(path):
    d = json.loads(line)
    su = [(s['index'], s['type'], s['hitpoints'], s['state'], s['linkedID']) for s in d.get('structures') or []]
    un = [(u['index'], u['type'], u['packed'], u['orient'], u['hp'], u['actionID']) for u in d['units']]
    cur = {'structures': (tuple(su),), 'units': (tuple(un),)}.get(what, (tuple(su), tuple(un)))
    if cur != prev:
        print(f"tick {d['tick']:>4}: structures={su}  units={un}")
        prev = cur
PY
