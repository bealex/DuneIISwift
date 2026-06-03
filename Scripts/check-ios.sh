#!/usr/bin/env bash
#
# Type-check the shared client + the iOS app sources against the iOS simulator SDK, without an Xcode project.
# A fast iOS-compat regression check: a single unconditionally-imported AppKit symbol or a macOS-only SwiftUI
# API in DuneIIClient breaks the real app build, but the macOS `swift build` never sees the `#if os(iOS)` code.
#
# This cross-compiles via `swift build` (the xcodebuild package-resolution sandbox is blocked in CI/sandboxes)
# into an isolated scratch dir so it never disturbs the macOS `.build`. It does NOT produce an app — that's
# `Scripts/build-ios.sh`.
#
set -euo pipefail
cd "$(dirname "$0")/../Code"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="arm64-apple-ios26.0-simulator"
SCRATCH="$PWD/.build-ios"
export TMPDIR="$PWD/.build/tmp"; mkdir -p "$TMPDIR"

ios_flags=(-Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc "$TARGET"
           -Xcc -isysroot -Xcc "$SDK" -Xcc -target -Xcc "$TARGET")

echo "▸ Cross-compiling DuneIIClient (+ engine) for iOS…"
out=$(xcrun swift build --disable-sandbox --scratch-path "$SCRATCH" --target DuneIIClient "${ios_flags[@]}" 2>&1 || true)
lib_errors=$(printf '%s\n' "$out" | grep -E "error:" | grep -E "Frameworks/|Apps/" || true)

echo "▸ Type-checking the iOS app sources…"
mods=$(find "$SCRATCH" -type d -name Modules | head -1)
app_errors=$(xcrun swiftc -typecheck -parse-as-library -sdk "$SDK" -target "$TARGET" -I "$mods" \
  Apps/duneii-ios/App.swift Apps/duneii-ios/ContentView.swift 2>&1 | grep -E "error:" | grep -v "using sysroot" || true)

if [ -z "$lib_errors$app_errors" ]; then
  echo "VERDICT: ✅ iOS sources compile"
else
  printf '%s\n%s\n' "$lib_errors" "$app_errors"
  echo "VERDICT: ❌ iOS-compat errors above"; exit 1
fi
