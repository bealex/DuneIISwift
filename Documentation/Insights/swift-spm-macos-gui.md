# Running a SwiftUI app from an SPM executable (macOS)

**Finding:** A native macOS SwiftUI `@main App` builds and runs as a plain SwiftPM executable (`swift run`) — AppKit, SwiftUI, CoreGraphics, ImageIO, and AVFoundation are all available to `swift build` on macOS. Only Mac Catalyst / UIKit needs an Xcode project. But an SPM executable is not a `.app` bundle, so by default it launches with no Dock presence / foreground window. Fix it with an `NSApplicationDelegate` (via `@NSApplicationDelegateAdaptor`): `NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)` in `applicationDidFinishLaunching`.

**Why it matters:** Lets us ship runnable macOS dev tools (the render-test inspector) without an Xcode project, keeping the whole build under `swift build`/`swift run`. The eventual Catalyst *game* app still needs Xcode.

**Evidence:** `Code/Apps/rendertest/App.swift` (`AppDelegate.applicationDidFinishLaunching`).

**How to apply:** For a macOS GUI dev tool, use a native SwiftUI/AppKit SPM executable target plus the activation-policy delegate. Reserve Xcode for Catalyst/UIKit targets.
