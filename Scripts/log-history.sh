#!/usr/bin/env bash
#
# log-history.sh — append a dated bullet to Documentation/History/YYYY-MM.md (workflow step 6), creating
# the month file with its header if it's new. Saves hand-formatting the `- YYYY-MM-DD: …` prefix and
# picking the right month file each turn.
#
# Usage:
#   Scripts/log-history.sh "Combat — ported Foo (file.swift); 244 tests green."   # text as one arg
#   Scripts/log-history.sh Combat — ported Foo, 244 tests green.                  # text as the rest of argv
#   echo "…long bullet with backticks…" | Scripts/log-history.sh                  # text on stdin (no args)
#   Scripts/log-history.sh --date 2026-06-01 "New-month entry"                    # override the date
#
# One bullet = one line (the repo's no-hard-wrap rule); newlines in the text are flattened to spaces.
# Prints the file it wrote and the appended line. Idempotency is NOT enforced — it appends every call.
#
# ⚠️  MAINTAIN with Scripts/check.sh: this dir is the single source of truth for the regular per-turn
#     actions. Fold in any new repeating step.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HISTDIR="$REPO/Documentation/History"

DATE="$(date +%Y-%m-%d)"
if [ "${1:-}" = "--date" ]; then
  DATE="${2:-}"
  shift 2
  case "$DATE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "log-history.sh: --date must be YYYY-MM-DD (got '$DATE')"; exit 2 ;;
  esac
fi
MONTH="${DATE%-*}"                         # YYYY-MM
FILE="$HISTDIR/$MONTH.md"

# Gather the bullet text: the rest of argv, else stdin.
if [ "$#" -gt 0 ]; then
  TEXT="$*"
else
  TEXT="$(cat)"
fi
# Flatten newlines → spaces, trim, and strip a leading "- "/"YYYY-MM-DD:" if the caller pre-formatted.
TEXT="$(printf '%s' "$TEXT" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ *//; s/ *$//')"
TEXT="${TEXT#- }"
TEXT="${TEXT#"$DATE": }"
if [ -z "$TEXT" ]; then echo "log-history.sh: empty bullet (pass text as args or on stdin)"; exit 2; fi

if [ ! -f "$FILE" ]; then
  mkdir -p "$HISTDIR"
  {
    printf '# History — %s\n\n' "$MONTH"
    printf 'Append-only changelog. One bullet per change, imperative mood, with file references.\n\n'
  } > "$FILE"
  echo "log-history.sh: created $FILE"
fi

printf -- '- %s: %s\n' "$DATE" "$TEXT" >> "$FILE"
echo "appended → $FILE"
tail -1 "$FILE"
