# duneii — module context

AppKit host executable for the SpriteKit rendering library. Boots the window, installs logging, wires the install's `AssetLoader`, and hands off to `GameController`.

## Layout

- `main.swift` — `NSApplicationMain`-style bootstrap: `AppDelegate` discovers the install, configures `Memoirs.Memoir` via `FileMemoir` + `LogRotator`, creates a `GameWindow`, and shows it.

## Conventions

- Keep this module tiny. Everything game-shaped lives in `DuneIIRendering` or lower. `main.swift` should only know about: install discovery, logging setup, window hookup, fatal-error presentation.
- `@MainActor` on the app delegate; AppKit requires it.
- If the install is missing, present a fatal `NSAlert` with a clear path hint. Do **not** try to run with a placeholder install.

## Running

```
cd Code/Core
swift run duneii
```

Runs from the project tree; `Installation.discover()` walks up for `Repositories/patched_107_unofficial`.

## Key entry points

- `AppDelegate.applicationDidFinishLaunching(_:)` — boot.
- `AppDelegate.setupLogging()` — installs `FileMemoir` + `LogRotator` under repo-root `Logs/`.
