#!/usr/bin/env bash
#
# check.sh — the standard per-round verification for the Swift package: build + tests, distilled to a
# CONCISE "what's wrong" summary. Run this instead of re-typing the build/test incantation each round.
#
# Usage:
#   Scripts/check.sh                  # incremental build + full test suite (fast inner loop)
#   Scripts/check.sh --full           # `swift package clean` first — the zero-warnings audit (CLAUDE.md step 5)
#   Scripts/check.sh --filter NAME    # incremental build + only tests matching NAME (e.g. a suite/type name)
#   Scripts/check.sh --full --filter NAME
#
# Output: a few lines — BUILD / TESTS / VERDICT — plus the specific warnings, failing tests, and scenario
# divergences when something is wrong. Full logs land in Code/.build/check/{build,test}.log.
# Exit code: 0 = all green; 1 = build warnings/errors or test failures; 2 = bad arguments.
#
# It encapsulates this repo's environment quirks (see CurrentState.md): a repo-local TMPDIR + xcrun +
# --disable-sandbox, and recreating .build/tmp after `swift package clean`.
#
# ⚠️  MAINTAIN THIS SCRIPT. Whenever you catch yourself repeating a manual step round after round — a new
#     check, an output-parse, a probe you keep re-typing — fold it in here (or add a sibling in Scripts/).
#     This file is meant to be the single source of truth for "the regular actions I do each round."
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE="$REPO/Code"
TMP="$CODE/.build/tmp"
LOGDIR="$CODE/.build/check"

FULL=0
FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full)   FULL=1 ;;
    --filter) FILTER="${2:-}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "check.sh: unknown argument '$1' (try --help)"; exit 2 ;;
  esac
  shift
done

cd "$CODE"
mkdir -p "$TMP" "$LOGDIR"
export TMPDIR="$TMP"
BUILD_LOG="$LOGDIR/build.log"
TEST_LOG="$LOGDIR/test.log"

# ── Build ─────────────────────────────────────────────────────────────────────
if [ "$FULL" = 1 ]; then
  xcrun swift package clean >/dev/null 2>&1 || true
  mkdir -p "$TMP" "$LOGDIR"            # clean wipes all of .build, so recreate the TMPDIR + log dir
fi

xcrun swift build --disable-sandbox >"$BUILD_LOG" 2>&1
BUILD_RC=$?
WARNINGS="$(grep -E 'warning:' "$BUILD_LOG" | sort -u || true)"
ERRORS="$(grep -E 'error:' "$BUILD_LOG" | sort -u || true)"
NW=$([ -z "$WARNINGS" ] && echo 0 || printf '%s\n' "$WARNINGS" | grep -c .)
NE=$([ -z "$ERRORS" ] && echo 0 || printf '%s\n' "$ERRORS" | grep -c .)

# ── Test (only if the build is clean enough to link) ──────────────────────────
TEST_RAN=0
if [ "$BUILD_RC" = 0 ] && [ "$NE" = 0 ]; then
  TEST_RAN=1
  if [ -n "$FILTER" ]; then
    xcrun swift test --disable-sandbox --filter "$FILTER" >"$TEST_LOG" 2>&1 || true
  else
    xcrun swift test --disable-sandbox >"$TEST_LOG" 2>&1 || true
  fi
fi
SUMMARY="$(grep -E 'Test run with .* test' "$TEST_LOG" 2>/dev/null | tail -1)"
ISSUES="$(grep -E 'Expectation failed|recorded an issue|error:|Fatal error' "$TEST_LOG" 2>/dev/null \
            | sed 's/^[^A-Za-z0-9"(]*//' | sort -u | head -20)"
DIVERGE="$(grep -E 'divergence at tick' "$TEST_LOG" 2>/dev/null | sed 's/^[^A-Za-z0-9]*//' | head -10)"

# ── Concise summary ───────────────────────────────────────────────────────────
MODE=$([ "$FULL" = 1 ] && echo "full/clean" || echo "incremental")
echo "=== check ($MODE${FILTER:+, filter=$FILTER}) ==="

GREEN=1
if [ "$BUILD_RC" != 0 ] || [ "$NE" != 0 ]; then
  echo "BUILD: ❌ FAILED — $NE error(s), $NW warning(s)"
  [ -n "$ERRORS" ]   && printf '%s\n' "$ERRORS"   | head -20 | sed 's/^/  /'
  [ -n "$WARNINGS" ] && printf '%s\n' "$WARNINGS" | head -20 | sed 's/^/  /'
  GREEN=0
elif [ "$NW" != 0 ]; then
  echo "BUILD: ⚠️  links but $NW warning(s):"
  printf '%s\n' "$WARNINGS" | sed 's/^/  /'
  GREEN=0
elif [ "$FULL" = 1 ]; then
  echo "BUILD: ✅ clean, 0 warnings (full audit)"
else
  echo "BUILD: ✅ 0 warnings (incremental — run --full before declaring done)"
fi

if [ "$TEST_RAN" = 0 ]; then
  echo "TESTS: ⏭️  skipped (build did not link)"
  GREEN=0
elif printf '%s' "$SUMMARY" | grep -q 'passed'; then
  echo "TESTS: ✅ ${SUMMARY#*with }"
elif [ -n "$SUMMARY" ]; then
  echo "TESTS: ❌ ${SUMMARY#*with }"
  [ -n "$ISSUES" ]  && printf '%s\n' "$ISSUES"  | sed 's/^/  • /'
  [ -n "$DIVERGE" ] && printf '%s\n' "$DIVERGE" | sed 's/^/  ↪ /'
  GREEN=0
else
  echo "TESTS: ❓ no result line — tail of $TEST_LOG:"
  tail -6 "$TEST_LOG" | sed 's/^/  /'
  GREEN=0
fi

if [ "$GREEN" = 1 ]; then
  echo "VERDICT: ✅ all green"
  exit 0
fi
echo "VERDICT: ❌ not green (logs: $BUILD_LOG, $TEST_LOG)"
exit 1
