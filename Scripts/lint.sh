#!/usr/bin/env bash
#
# lint.sh — run SwiftLint over the Swift package sources with the project code-style rules.
#
# Usage:
#   Scripts/lint.sh              # lint Code/ (warnings + errors), concise summary
#   Scripts/lint.sh --strict     # treat every finding as an error (exit 1 on any warning)
#   Scripts/lint.sh --fix        # auto-correct the correctable violations in place
#   Scripts/lint.sh PATH ...     # restrict to the given files/dirs
#
# Config: .swiftlint.yml (repo root) — indented switch cases, 120-col lines, mandatory trailing commas,
# sorted imports, one-arg-per-line on wrapped calls, no blank lines hugging braces. Pure layout
# (indentation, brace placement) is owned by Scripts/format.sh; this catches the lint-only concerns.
#
# Override the binary with SWIFTLINT=/path/to/swiftlint if needed.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO/.swiftlint.yml"
LINT_BIN="${SWIFTLINT:-swiftlint}"

if ! command -v "$LINT_BIN" >/dev/null 2>&1; then
  echo "lint.sh: '$LINT_BIN' not found (install via \`brew install swiftlint\`)"; exit 2
fi

MODE="lint"
STRICT=()
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)     MODE="fix" ;;
    --strict)  STRICT=(--strict) ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *)         PATHS+=("$1") ;;
  esac
  shift
done

# Run from the repo root so the `included:`/`excluded:` globs in .swiftlint.yml resolve.
cd "$REPO"

if [ "$MODE" = "fix" ]; then
  "$LINT_BIN" --fix --config "$CONFIG" ${PATHS[@]+"${PATHS[@]}"}
  echo "lint ✅ applied auto-corrections (re-run Scripts/lint.sh to see what remains)"
  exit 0
fi

OUT="$("$LINT_BIN" lint --config "$CONFIG" --quiet ${STRICT[@]+"${STRICT[@]}"} ${PATHS[@]+"${PATHS[@]}"} 2>&1)"
RC=$?

if [ -n "$OUT" ]; then printf '%s\n' "$OUT"; fi

WARN=$(printf '%s\n' "$OUT" | grep -c ' warning: ' || true)
ERR=$(printf '%s\n' "$OUT" | grep -c ' error: ' || true)
echo "── lint summary: $WARN warning(s), $ERR error(s) ──"

if [ "$RC" = 0 ]; then exit 0; fi
exit 1
