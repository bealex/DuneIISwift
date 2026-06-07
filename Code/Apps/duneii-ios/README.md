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
app reads them from `Bundle.main/GameData`, where macOS reads the install dir. The **music** (`Resources/Audio/Music/*.ADL`)
is likewise staged into `Audio/Music/` and bundled (the sandboxed app can't read the repo path the macOS app
uses); both `GameData/` and `Audio/` are git-ignored. iOS audio also needs an active `AVAudioSession`
(`.playback`), configured in `App.swift` — without it `AVAudioEngine` produces no sound.

## Build & deploy

```sh
Scripts/build-ios.sh sim                      # build + install + launch on the iOS Simulator (no signing)
Scripts/build-ios.sh device                   # … on the first connected iPhone/iPad
Scripts/build-ios.sh device "<name or UDID>"  # … on a specific device (name substring or UDID; or DUNEII_DEVICE=…)
Scripts/build-ios.sh archive                  # Release archive + export a signed .ipa for TestFlight / Ad-Hoc
```

The script stages the PAKs, runs `xcodegen`, then `xcodebuild`. Override the install dir with
`DUNEII_INSTALL=/path/to/dune2`. Bundle id `com.lonelybytes.duneii`, automatic signing. Set your device and
Apple Developer team via a git-ignored `.env` (`DUNEII_DEVICE` / `DUNEII_TEAM`) — see `.env.example`.

**`device`/`archive` prereqs:** `xcodegen` installed (the script offers `brew install xcodegen`), **and** your
developer Apple ID for your team (`DUNEII_TEAM`) logged into **Xcode ▸ Settings ▸ Accounts** — `-allowProvisioningUpdates`
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

The sidebar's popovers (Mentat, Options, Scenario, Requirements) are sized via `gamePopover(width:maxHeight:)`
(`DuneIIClient/PopoverLayout.swift`): a landscape-appropriate width plus a `maxHeight` that lets the popover
clamp to a short screen while its inner `List`/`Form`/`ScrollView` scrolls the overflow. This is presentation
only (no OpenDUNE oracle, not captured by a render golden), so verify by hand on a small landscape iPhone:

- Open each of the four popovers on the **shortest** target (e.g. iPhone XR landscape) — none should clip; the
  long ones (Mentat detail, Options/DebugPanel, Scenario list) must scroll to reveal the rest.
- Each popover stays an **anchored popover** (with the arrow) rather than adapting into a bottom sheet.
