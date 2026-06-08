#!/bin/zsh
# Wrap the SwiftPM `duneii` executable into a branded macOS .app bundle (so it gets the
# Dock/Finder app icon — `swift run duneii` is a bare binary with no bundle/icon).
#
#   Scripts/bundle-mac.sh [debug|release]   # default: release
#
# Output: build/mac/duneii.app  (double-click to launch, or `open build/mac/duneii.app`).
# The icon is Code/Apps/duneii/AppIcon.icns (regenerate art with Scripts/gen-app-icon.swift).
set -euo pipefail

ROOT="${0:A:h:h}"                       # repo root (Scripts/.. )
CONFIG="${1:-release}"
APP="$ROOT/build/mac/duneii.app"
ICNS="$ROOT/Code/Apps/duneii/AppIcon.icns"
BUNDLE_ID="com.lonelybytes.duneii"

say() { print -P "%F{cyan}▸ $*%f"; }

say "Building duneii ($CONFIG)…"
cd "$ROOT/Code"
TMPDIR="$PWD/.build/tmp" xcrun swift build -c "$CONFIG" --product duneii --disable-sandbox
BIN="$(TMPDIR="$PWD/.build/tmp" xcrun swift build -c "$CONFIG" --show-bin-path --disable-sandbox)/duneii"
[ -x "$BIN" ] || { print "build produced no duneii binary at $BIN" >&2; exit 1; }
[ -f "$ICNS" ] || { print "missing icon $ICNS — run Scripts/gen-app-icon.swift first" >&2; exit 1; }

say "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/duneii"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Dune II</string>
  <key>CFBundleDisplayName</key><string>Dune II</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>duneii</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
# Refresh Finder's icon cache for the rebuilt bundle.
touch "$APP"
say "Built $APP"
