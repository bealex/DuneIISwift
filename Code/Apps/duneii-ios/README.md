# duneii-ios — the iOS game client

The iOS build of Dune II. It shares **everything** with the macOS app via `DuneIIClient` — the same
`GameModel`, `GameSidebar` (radar, selection, build list, starport cart, Mentat, Options), `GameScene`, and
renderer. Only this shell differs:

- **`App.swift`** — the `@main` SwiftUI `App` (no `NSApplication`/Settings scene).
- **`ContentView.swift`** — a full-screen `SpriteView` map + the shared `GameSidebar` on the trailing edge
  (the same layout as macOS, which already dropped its window toolbar). Save/Load use a quicksave slot in the
  app's Documents directory.

**Touch input** lives in `GameScene` (`#if os(iOS)`): tap = select / place / apply an armed order, one-finger
drag = pan, two-finger pinch = zoom, long-press = the default order (the macOS right-click). The radar
recentres the map on tap/drag.

There is **no committed `.xcodeproj`** — it's generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The original game `*.PAK` files are **not** committed
(copyrighted); the build script copies them from the install into `GameData/` and bundles them — on device the
app reads them from `Bundle.main/GameData`, where macOS reads the install dir.

## Build & deploy

```sh
Scripts/build-ios.sh sim                      # build + install + launch on the iOS Simulator (no signing)
Scripts/build-ios.sh device                   # … on the first connected iPhone/iPad
Scripts/build-ios.sh device "a specific device"  # … on a specific device (name substring or UDID; or DUNEII_DEVICE=…)
Scripts/deploy-iphone17.sh                    # convenience wrapper for `device "a specific device"`
Scripts/build-ios.sh archive                  # Release archive + export a signed .ipa for TestFlight / Ad-Hoc
```

The script stages the PAKs, runs `xcodegen`, then `xcodebuild`. Override the install dir with
`DUNEII_INSTALL=/path/to/dune2`. Bundle id `com.lonelybytes.duneii`, team `REDACTED_TEAM`, automatic signing.

**`device`/`archive` prereqs:** `xcodegen` installed (the script offers `brew install xcodegen`), **and** your
developer Apple ID for team `REDACTED_TEAM` logged into **Xcode ▸ Settings ▸ Accounts** — `-allowProvisioningUpdates`
then mints a development certificate + provisioning profile automatically (a one-time interactive trust/sign-in
may be needed). The **`sim`** path needs neither and is the quickest smoke test.

## Verify iOS-compat without a device

```sh
Scripts/check-ios.sh            # cross-compiles the shared client + app sources against the iOS SDK
```

This type-checks the `#if os(iOS)` code the macOS build never sees (a stray unconditional `import AppKit` or a
macOS-only SwiftUI API would otherwise only surface in the real app build).

## Layout vs. iPhone

The map + 250 pt sidebar suits iPad and landscape iPhone, so the app is **landscape-only**. On a small iPhone
the sidebar is proportionally large; an iPhone-tuned layout (collapsible sidebar) is a future refinement.
