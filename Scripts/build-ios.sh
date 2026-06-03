#!/usr/bin/env bash
#
# Build + deploy the Dune II iOS app (Code/Apps/duneii-ios).
#
#   Scripts/build-ios.sh [sim|device|archive] ["<device name|UDID>"]   (default: sim)
#
#     sim      Build for the iOS Simulator, then install + launch on a booted/first simulator.
#     device   Build for a connected iPhone/iPad, then install + launch (needs your Apple ID logged into
#              Xcode for automatic signing — team REDACTED_TEAM). Pass a device name substring or UDID as the
#              2nd arg (or set DUNEII_DEVICE); default = the first connected device.
#              e.g.  Scripts/build-ios.sh device "a specific device"
#     archive  Release archive + export a signed .ipa under build/ios/export (for TestFlight / Ad-Hoc).
#
# Prereqs: Xcode, and `xcodegen` (the script offers to `brew install` it if missing). The original game
# PAKs are bundled into the app from the install dir — set DUNEII_INSTALL to override.
#
set -euo pipefail

MODE="${1:-sim}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/Code/Apps/duneii-ios"
PROJECT="$IOS_DIR/duneii-ios.xcodeproj"
SCHEME="duneii-ios"
BUNDLE_ID="com.lonelybytes.duneii"
TEAM="REDACTED_TEAM"
INSTALL="${DUNEII_INSTALL:-$ROOT/Repositories/patched_107_unofficial}"
DD="$ROOT/build/ios/dd"          # DerivedData
GAMEDATA="$IOS_DIR/GameData"

say() { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- xcodegen ----
ensure_xcodegen() {
  command -v xcodegen >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then
    say "xcodegen not found — installing via Homebrew…"
    brew install xcodegen
  elif command -v mint >/dev/null 2>&1; then
    say "xcodegen not found — installing via Mint…"
    mint install yonaskolb/XcodeGen
  else
    die "xcodegen is required. Install it with:  brew install xcodegen  (or: mint install yonaskolb/XcodeGen)"
  fi
}

# --------------------------------------------------------------- game data ----
stage_assets() {
  [ -d "$INSTALL" ] || die "Game install not found at: $INSTALL  (set DUNEII_INSTALL=/path/to/dune2)"
  local paks; paks=$(ls "$INSTALL"/*.PAK 2>/dev/null | wc -l | tr -d ' ')
  [ "$paks" -gt 0 ] || die "No .PAK files in $INSTALL"
  say "Bundling $paks PAK files into the app…"
  rm -rf "$GAMEDATA"; mkdir -p "$GAMEDATA"
  cp "$INSTALL"/*.PAK "$GAMEDATA"/
}

# ------------------------------------------------------------- generate ----
generate() {
  say "Generating Xcode project…"
  ( cd "$IOS_DIR" && xcodegen generate --quiet )
}

app_path() {  # $1 = Debug-iphonesimulator | Debug-iphoneos
  find "$DD/Build/Products/$1" -maxdepth 1 -name '*.app' | head -1
}

# ------------------------------------------------------------------- sim ----
deploy_sim() {
  local udid
  udid=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    if "iOS" not in rt: continue
    for x in devs:
        if x["state"]=="Booted": print(x["udid"]); sys.exit()
        if best is None and ("iPad" in x["name"] or "iPhone" in x["name"]): best=x["udid"]
print(best or "")')
  [ -n "$udid" ] || die "No iOS simulator available. Create one in Xcode ▸ Settings ▸ Components."
  say "Building for the simulator…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build | xcbeautify_or_cat
  local app; app=$(app_path Debug-iphonesimulator); [ -n "$app" ] || die "Build produced no .app"
  say "Installing on simulator…"
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install "$udid" "$app"
  xcrun simctl launch "$udid" "$BUNDLE_ID"
  say "Launched $BUNDLE_ID on the simulator."
}

# Resolve a device name-substring (or pass a UDID through) to its hardware UDID via `xctrace`.
resolve_device() {
  local q="$1"
  if printf '%s' "$q" | grep -qiE '^[0-9A-F]{8}-[0-9A-F]{16}$|^[0-9a-f]{40}$'; then echo "$q"; return; fi
  xcrun xctrace list devices 2>/dev/null | grep -v "Simulator" | grep -i "$q" \
    | grep -oE '\([0-9A-Fa-f-]{20,}\)[[:space:]]*$' | tr -d '()' | head -1
}

# ---------------------------------------------------------------- device ----
# $1 (optional) = device name substring or UDID. Defaults to DUNEII_DEVICE, else the first connected one.
deploy_device() {
  local want="${1:-${DUNEII_DEVICE:-}}" udid
  if [ -n "$want" ]; then
    udid=$(resolve_device "$want")
    [ -n "$udid" ] || die "Device '$want' not found. List devices: xcrun xctrace list devices"
  else
    udid=$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | /usr/bin/python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d.get("result",{}).get("devices",[]):
    cp=x.get("connectionProperties",{})
    if cp.get("tunnelState")!="unavailable" and x.get("hardwareProperties",{}).get("platform","")=="iOS":
        print(x["hardwareProperties"]["udid"]); break' || true)
  fi
  [ -n "$udid" ] || die "No connected iPhone/iPad found. Plug one in, unlock it, and Trust this Mac."
  say "Building + signing for device $udid (team $TEAM)…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$DD" \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build | xcbeautify_or_cat
  local app; app=$(app_path Debug-iphoneos); [ -n "$app" ] || die "Build produced no .app"
  say "Installing on device…"
  xcrun devicectl device install app --device "$udid" "$app"
  xcrun devicectl device process launch --device "$udid" "$BUNDLE_ID" || true
  say "Installed $BUNDLE_ID on the device."
}

# --------------------------------------------------------------- archive ----
archive() {
  local arch="$ROOT/build/ios/duneii.xcarchive" exp="$ROOT/build/ios/export"
  say "Archiving (Release, signed)…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$arch" \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates archive | xcbeautify_or_cat
  local opts="$ROOT/build/ios/ExportOptions.plist"
  cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  say "Exporting .ipa…"
  rm -rf "$exp"
  xcodebuild -exportArchive -archivePath "$arch" -exportPath "$exp" \
    -exportOptionsPlist "$opts" -allowProvisioningUpdates | xcbeautify_or_cat
  say "Exported to $exp"
  say "Upload to TestFlight with:  xcrun altool --upload-app -f \"$exp\"/*.ipa -t ios --apiKey … --apiIssuer …"
}

xcbeautify_or_cat() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi }

# -------------------------------------------------------------------- main ----
ensure_xcodegen
stage_assets
generate
case "$MODE" in
  sim)     deploy_sim ;;
  device)  deploy_device "${2:-}" ;;       # e.g.  build-ios.sh device "a specific device"
  archive|testflight) archive ;;
  *) die "Unknown mode '$MODE'. Use: sim | device | archive" ;;
esac
