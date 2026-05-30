#!/usr/bin/env bash
#
# build-oracle.sh — rebuild + ad-hoc re-sign the OpenDUNE parity oracle. Run after editing
# Repositories/OpenDUNE/src/parity.c (the golden/scenario/trace dumpers) so the next golden generation or
# RNG trace uses the new code.
#
# Encapsulates two environment gotchas (see CurrentState.md / insight build-exec-eperm):
#   1. the .shim/gcc → `xcrun clang` shim (a direct clang/gcc exec is EPERM in the sandbox);
#   2. a relinked bin/opendune is SIGKILLed on exec ("killed", no output) until re-signed ad-hoc, because
#      the stale code signature is invalidated by the relink.
#
# Note: `make` invokes the compiler, so run this with the sandbox disabled.
# Exit code: 0 = built + signed; 1 = build failed.
#
# ⚠️  MAINTAIN THIS SCRIPT alongside Scripts/check.sh — fold in any new recurring oracle step.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORACLE="$REPO/Repositories/OpenDUNE"

cd "$ORACLE"
if ! PATH="$PWD/.shim:$PATH" make -j4 "$@"; then
  echo "❌ oracle build failed"
  exit 1
fi
codesign --force --sign - bin/opendune
echo "✅ oracle built + signed: $ORACLE/bin/opendune"
