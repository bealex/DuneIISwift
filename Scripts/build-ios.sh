#!/usr/bin/env bash
#
# Build + deploy the Dune II iOS app (Code/Apps/duneii-ios).
#
#   Scripts/build-ios.sh [sim|device|archive] ["<device name|UDID>"]   (default: sim)
#
#     sim      Build for the iOS Simulator, then install + launch on a booted/first simulator.
#     device   Build for a connected iPhone/iPad, then install + launch (needs your Apple ID logged into
#              Xcode for automatic signing — set DUNEII_TEAM to your team ID). Pass a device name substring or
#              UDID as the 2nd arg (or set DUNEII_DEVICE); default = the first connected device.
#              e.g.  Scripts/build-ios.sh device "<name substring or UDID>"
#     archive  Release archive + export a signed .ipa under build/ios/export (for TestFlight / Ad-Hoc).
#
# Prereqs: Xcode, and `xcodegen` (the script offers to `brew install` it if missing). The original game
# PAKs are bundled into the app from the install dir — set DUNEII_INSTALL to override. Device/team identifiers
# are read from a git-ignored `.env` (DUNEII_DEVICE / DUNEII_TEAM) — see `.env.example`.
#
set -euo pipefail

# Make Homebrew-installed tools (xcodegen, xcbeautify) resolvable even when this script runs from a
# non-interactive shell that never sourced the user's profile — e.g. an agent/CI shell whose PATH lacks
# /opt/homebrew/bin. Without this, `command -v xcodegen` fails and the script wrongly reports it as missing
# although it is installed, so you had to export PATH by hand every run.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

MODE="${1:-sim}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Local, git-ignored config: device + Apple Developer team identifiers (DUNEII_DEVICE / DUNEII_TEAM). Kept
# out of version control so personal IDs aren't published; see `.env.example`.
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

IOS_DIR="$ROOT/Code/Apps/duneii-ios"
PROJECT="$IOS_DIR/duneii-ios.xcodeproj"
SCHEME="duneii-ios"
BUNDLE_ID="com.lonelybytes.duneii"
TEAM="${DUNEII_TEAM:-}"
INSTALL="${DUNEII_INSTALL:-$ROOT/Repositories/patched_107_unofficial}"
DD="$ROOT/build/ios/dd"          # DerivedData
GAMEDATA="$IOS_DIR/GameData"
AUDIODIR="$IOS_DIR/Audio"        # bundled music (Audio/Music/*.ADL) — staged from Resources/, git-ignored

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

  # Music: the macOS app reads Resources/Audio/Music from disk; the sandboxed iOS app needs it bundled under
  # Audio/Music/ (where GameModel.musicURL looks: Bundle.main/Audio/Music). Without it there's no in-game music.
  local music="$ROOT/Resources/Audio/Music"
  rm -rf "$AUDIODIR"
  if [ -d "$music" ]; then
    local n; n=$(ls "$music" 2>/dev/null | wc -l | tr -d ' ')
    say "Bundling $n music files into the app…"
    mkdir -p "$AUDIODIR/Music"
    cp "$music"/* "$AUDIODIR/Music"/
  else
    say "No music at $music — the app will build without in-game music."
  fi
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
    # `devicectl list devices -j /dev/stdout | python` is unreliable — the JSON frequently arrives empty over
    # the pipe, which made auto-detect wrongly report "no device". Write it to a file and parse that, picking
    # the first *connected* iOS device.
    local devjson="$DD/_devices.json"; mkdir -p "$DD"
    xcrun devicectl list devices -j "$devjson" >/dev/null 2>&1 || true
    udid=$(/usr/bin/python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
for x in d.get("result",{}).get("devices",[]):
    hp=x.get("hardwareProperties",{}); cp=x.get("connectionProperties",{})
    if hp.get("platform")=="iOS" and cp.get("tunnelState")=="connected":
        print(hp.get("udid","")); break' "$devjson" || true)
  fi
  [ -n "$udid" ] || die "No connected iPhone/iPad found. Plug one in, unlock it, and Trust this Mac."
  # Build for a *generic* iOS destination, not `id=$udid`. A device-targeted build makes xcodebuild prepare/
  # connect to that device first, which hangs indefinitely for a wireless-only (localNetwork) device. Building
  # generic compiles + signs offline; `devicectl` then handles the (wireless) install.
  # NOTE: `-allowProvisioningUpdates` is deliberately omitted. With it, xcodebuild calls Apple's Developer
  # portal to create/refresh the signing cert + profile — a network round-trip that, in a headless/non-
  # interactive context, hangs ~30 min and dies with `curl: (28) Operation timed out`. Without it, signing
  # uses only the locally-cached cert/profile and **fails fast** with the real error (e.g. "No profiles for
  # 'com.lonelybytes.duneii' were found") instead of hanging. `set -euo pipefail` then breaks the build. If
  # signing fails this way, fix the profile/cert in Xcode once (it'll cache them) and re-run.
  say "Building + signing for iOS (team $TEAM)…"
  if ! run_capped xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
      DEVELOPMENT_TEAM="$TEAM" build | xcbeautify_or_cat; then
    die "Build/sign failed or exceeded ${DUNEII_BUILD_TIMEOUT:-300}s. Most likely signing couldn't reach Apple \
or there's no valid cached profile/cert for $BUNDLE_ID. Fix signing once in Xcode (open the project, select a \
team, Run), then re-run — or use 'Scripts/build-ios.sh sim' which needs no signing."
  fi
  local app; app=$(app_path Debug-iphoneos); [ -n "$app" ] || die "Build produced no .app"
  say "Installing on device ${udid}…"
  xcrun devicectl device install app --device "$udid" "$app" \
    || die "Install failed — make sure the iPhone is unlocked and on the same network (or plug in via USB)."
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

# Run a command with a hard wall-clock cap so a stuck signing/network call BREAKS instead of hanging ~30 min.
# macOS ships no coreutils `timeout` (and perl isn't guaranteed), so use a pure-bash watchdog: run the command
# in the background and SIGTERM it after DUNEII_BUILD_TIMEOUT seconds (default 600). Even without
# `-allowProvisioningUpdates`, automatic signing still contacts Apple's portal; if that's unreachable the call
# hangs to curl's 30-min timeout — this caps it. Returns the command's exit (143 if the watchdog killed it).
run_capped() {
  local secs="${DUNEII_BUILD_TIMEOUT:-600}"
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local guard=$!
  local rc=0
  wait "$pid" || rc=$?
  kill -TERM "$guard" 2>/dev/null || true
  wait "$guard" 2>/dev/null || true
  return "$rc"
}

# -------------------------------------------------------------------- main ----
ensure_xcodegen
stage_assets
generate
case "$MODE" in
  sim)     deploy_sim ;;
  device)  deploy_device "${2:-}" ;;       # e.g.  build-ios.sh device "<name substring or UDID>"
  archive|testflight) archive ;;
  *) die "Unknown mode '$MODE'. Use: sim | device | archive" ;;
esac
