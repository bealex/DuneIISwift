#!/usr/bin/env bash
#
# log-history.sh — append a bullet to today's daily history file Documentation/History/YYYY-MM-DD.md
# (workflow step 6), creating the day file (with its `# History — DATE` header) if it's new and adding a
# link for the new day to the top of the History/README.md "Days" index. Saves hand-picking the day file
# and formatting the bullet each turn. The day is encoded in the filename, so bullets carry no date prefix.
#
# Usage:
#   Scripts/log-history.sh "Combat — ported Foo (file.swift); 244 tests green."   # text as one arg
#   Scripts/log-history.sh Combat — ported Foo, 244 tests green.                  # text as the rest of argv
#   echo "…long bullet with backticks…" | Scripts/log-history.sh                  # text on stdin (no args)
#   Scripts/log-history.sh --date 2026-06-01 "Back-dated entry"                   # override the date
#
# One bullet = one line (the repo's no-hard-wrap rule); newlines in the text are flattened to spaces.
# Prints the file it wrote and the appended line. Idempotency is NOT enforced — it appends every call.
# When it creates a new day, it inserts `- [DATE](DATE.md) — ` atop README's Days list; fill the summary.
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
FILE="$HISTDIR/$DATE.md"
INDEX="$HISTDIR/README.md"

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
  printf '# History — %s\n\n' "$DATE" > "$FILE"
  echo "log-history.sh: created $FILE"
  # Add a link for the new day to the top of README's Days list (newest first), if the index is present.
  if [ -f "$INDEX" ] && grep -q '($DATE.md)' "$INDEX"; then :; elif [ -f "$INDEX" ] && grep -q '^## Days' "$INDEX"; then
    # Insert the new day's link just before the first existing day link (newest first), keeping the list tight.
    awk -v line="- [$DATE]($DATE.md) — " '
      /^- \[[0-9]/ && !done { print line; done=1 }
      { print }
    ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "log-history.sh: indexed $DATE in $INDEX (add a one-line summary)"
  fi
fi

printf -- '- %s\n' "$TEXT" >> "$FILE"
echo "appended → $FILE"
tail -1 "$FILE"
