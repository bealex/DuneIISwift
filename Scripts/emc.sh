#!/usr/bin/env bash
#
# emc.sh — disassemble a Dune II EMC script (UNIT / BUILD / TEAM) and optionally slice out one type's
# routine or the shared-subroutine region. Wraps `assetgen emc-disasm` + the per-type awk slicing that
# every EMC-porting slice re-derives by hand.
#
# Usage:  Scripts/emc.sh <unit|build|team> [N | --linear | all]
#   N         → just type N's routine (e.g. `Scripts/emc.sh build 12` = the refinery script)
#   --linear  → the whole program linearly — exposes the shared subroutines below the lowest type entry
#               (a structure's death / turret / refine common code) that the per-type view never reaches
#   all|omit  → the full per-type listing (default)
#
# ⚠️  MAINTAIN alongside the other Scripts/.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
which="${1:-}"
sel="${2:-all}"
[ -n "$which" ] || { echo "usage: emc.sh <unit|build|team> [N|--linear|all]" >&2; exit 2; }

case "$which" in
  unit)            f="$REPO/Resources/Scripts/UNIT/UNIT.emc";  kind=unit ;;
  build|structure) f="$REPO/Resources/Scripts/BUILD/BUILD.emc"; kind=structure ;;
  team)            f="$REPO/Resources/Scripts/TEAM/TEAM.emc";  kind=team ;;
  *) echo "unknown script '$which' (expected unit|build|team)" >&2; exit 2 ;;
esac

cd "$REPO/Code"
mkdir -p .build/tmp
dis() { TMPDIR="$PWD/.build/tmp" xcrun swift run --disable-sandbox assetgen emc-disasm "$f" "$kind" "$@" 2>/dev/null; }

case "$sel" in
  --linear) dis --linear ;;
  all)      dis ;;
  *)        dis | awk -v hdr="; ---- type ${sel} (" '
              index($0, hdr) == 1 { p = 1; print; next }
              p && /^; ---- type / { exit }
              p { print }
            ' ;;
esac
