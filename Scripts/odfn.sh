#!/usr/bin/env bash
#
# odfn.sh — print an OpenDUNE C function body (and its file:line) from the reference source. This is the
# single most-repeated investigation command when porting a primitive: instead of re-typing
#   sed -n '/^uint16 Foo_Bar(/,/^}/p' Repositories/OpenDUNE/src/<guess>.c
# run:  Scripts/odfn.sh Foo_Bar
# It finds the definition anywhere under src/ and prints from the def line to the first column-0 `}`
# (OpenDUNE formats every function body's closing brace at column 0). With multiple definitions (rare),
# all are printed. If there's no .c body, the header declaration(s) are listed instead.
#
# Usage:  Scripts/odfn.sh <FunctionName>
#
# ⚠️  MAINTAIN alongside the other Scripts/ — fold in recurring source-reading patterns.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/Repositories/OpenDUNE/src"
name="${1:-}"
[ -n "$name" ] || { echo "usage: odfn.sh <FunctionName>" >&2; exit 2; }

# A definition line starts at column 0 with a return type, contains `<name>(`, and does NOT end in `;`
# (that would be a prototype). Find the file(s), then print each body def-line → first column-0 `}`.
# (Plain word-split loop, not `mapfile` — the system bash is 3.2; OpenDUNE src paths have no spaces.)
files="$(grep -rlE "^[A-Za-z].*[ *]${name}\(" "$SRC" --include='*.c' 2>/dev/null || true)"

if [ -z "$files" ]; then
  echo "// no .c definition of '${name}' — header declaration(s):" >&2
  grep -rnE "\b${name}\(" "$SRC" --include='*.h' | head -10
  exit 1
fi

for f in $files; do
  awk -v n="$name" '
    $0 ~ ("^[A-Za-z].*[ *]" n "\\(") && $0 !~ /;[ \t]*$/ { print "// " FILENAME ":" FNR; inbody = 1 }
    inbody { print }
    inbody && /^}/ { inbody = 0; print "" }
  ' "$f"
done
