# Type-check iOS-only code with `swift build` cross-compilation, not `xcodebuild`

**Finding:** the macOS `swift build` never compiles the `#if os(iOS)` branches, so a stray unconditional
`import AppKit`, a macOS-only SwiftUI API (`SettingsLink`), or a typo in a touch handler stays invisible until
the real iOS app build. And `xcodebuild` can't be used to catch it in a sandbox/CI: its package-graph
resolution shells out to `sandbox-exec`, which a nested sandbox denies (`posix_spawn: Operation not permitted`).
The way to type-check the iOS paths is to cross-compile the **SwiftPM** package against the iOS-simulator SDK:

```sh
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --disable-sandbox --scratch-path .build-ios --target DuneIIClient \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios26.0-simulator \
  -Xcc -isysroot -Xcc "$SDK" -Xcc -target -Xcc arm64-apple-ios26.0-simulator
```

**Why it matters:** without this there is no iOS compile feedback in the headless environment — the iOS app
only fails on the user's machine. `swift build --disable-sandbox` sidesteps the manifest sandbox that blocks
`xcodebuild`; the iOS SDK + target make it compile the `#if os(iOS)` code and the real iOS framework headers.

**Two gotchas:**
1. Passing only `-Xswiftc -sdk …` is **not enough** — the clang module importer still uses the macOS sysroot
   and every Obj-C framework module (`SpriteKit`, `AudioToolbox`, `UIKit`) fails to build. You must **also**
   pass `-Xcc -isysroot -Xcc "$SDK"` (and `-Xcc -target`). With both, the only remaining noise is a benign
   `warning: using sysroot for 'MacOSX' but targeting 'iPhone'`.
2. App targets that aren't SwiftPM targets (an Xcode `@main` app) won't be in `swift build`. Type-check those
   files separately with `swiftc -typecheck -parse-as-library -sdk "$SDK" -target … -I <iOS Modules dir>`,
   pointing `-I` at the cross-compiled `…/debug/Modules`.

**Evidence:** `Scripts/check-ios.sh` (the reusable check), `Scripts/build-ios.sh` (the real app build via
XcodeGen + xcodebuild, run on a Mac with signing). This caught the unconditional `import AppKit` in
`Minimap.swift` and `SettingsLink` in `Sidebar.swift` (`OptionsPopover`).

**How to apply:** run `Scripts/check-ios.sh` whenever shared `DuneIIClient` code changes (or before shipping an
iOS build). Use an isolated `--scratch-path` so the iOS objects don't poison the macOS `.build` and force a
needless rebuild.
