# DuneIIRendering — module context

SpriteKit + AppKit presentation layer. Owns scene lifecycle, pure-state-machine controllers, asset loading from a discovered install, audio playback, and file-based logging wiring. No simulation logic lives here — everything flows through `DuneIICore`'s pools and `Simulation.Scheduler`.

## Layout

- `AppMenu.swift` — `NSMenu` hookup.
- `AssetLoader.swift` — cached PAK catalog + decoders (palette, iconmap, `TileResolver`, CPS / SHP / ICN / WSA / scenario / EMC / XMI / VOC). Higher-level helpers wrap `DuneIICore`'s `Formats.*` decoders with on-disk discovery.
- `CGImageFactory.swift` — palette → `CGImage`, SHP / CPS frames → `CGImage`, per-house palette remap composition.
- `GameController.swift` — `SceneCoordinator` that drives boot flow (Intro → Scenario) and owns the `Jukebox` / `Voice`.
- `GameWindow.swift` — `NSWindow` host + `SKView`.
- `HouseColors.swift` — six canonical house `NSColor`s + a factional `NSColor` lookup.
- `Installation.swift` — walks up from CWD to find the 1.07 install and builds a case-insensitive PAK catalog.
- `UnitSpriteAtlas.swift` — lazy per-house `[SKTexture?]` atlas across `UNITS.SHP` / `UNITS1.SHP` / `UNITS2.SHP`, keyed by global sprite ID.
- `Audio/`
  - `Jukebox.swift` — `AVMIDIPlayer` wrapper for XMI → SMF playback.
  - `Voice.swift` — `AVAudioEngine` + `AVAudioPlayerNode`, u8-PCM remap to float.
- `Scene/`
  - `SceneCoordinator.swift` — protocol the controller implements so scenes can request transitions.
  - `IntroScene.swift` — `INTRO.WSA` playback at 15 fps.
  - `MainMenuScene.swift` / `MentatScene.swift` — currently bypassed by `GameController` (scenes load directly into ScenarioScene) but kept for reactivation.
  - `ScenarioScene.swift` — the big one. Loads a scenario, stamps tiles, builds the live `Simulation.WorldSnapshot` + `Scheduler`, drives it per-frame, renders unit/structure/explosion markers, hosts the build sidebar + HUD.
  - `BuildPanelController.swift` — pure state machine for the right-hand build sidebar (sidebar-click vs map-click, IDLE / BUSY / READY branching, enqueue / enterPlacement / commitPlacement / cancelConstruction actions).
  - `UnitCommandController.swift` — pure state machine for left/right click on units (select, deselect, orderMove, orderAttack).
- `Logging/`
  - `FileMemoir.swift` — `Memoirs.Memoir` implementation that writes line-formatted items to a serial queue.
  - `LogRotator.swift` — keeps `Logs/run-*.log` under the repo root, trimming to 10 newest.

## Conventions

- **Controllers are pure state machines.** `BuildPanelController` and `UnitCommandController` are `struct`s with `handle(click:...)` → `Action` methods. They know nothing about SpriteKit. All SKNode work happens in the scene; the controller just produces intent. Keep it that way — it's why they're testable without a test host.
- **Scenes own SKNode state.** Scene state goes in the `SKScene` subclass (`ScenarioScene`); per-frame mutation flows through `update(_:)` and `syncVisualsFromPool()`. Do not cache simulation state on scenes; re-read from `scheduler?.host` each tick.
- **Markers are lazy.** Unit / structure / explosion markers are created on first observation of an `isUsed` slot (see `syncUnits` / `syncStructures` / `syncExplosions`). Freed slots hide, not remove — reuse saves allocations.
- **Pos32 → scene.** Convert once, at the boundary: `screenPositionPos32(x:y:)`. The rest of the scene stays in scene-local CGPoints.
- **MainActor.** Everything in this module is `@MainActor`. Audio classes cross threads via `AVAudioEngine` — keep the surface API main-actor-isolated and let AVF manage its own queues internally.
- **Logging via `Log`.** Use `Log.info / .debug` with `tracer: .label("...")`. The file backend is installed in `duneii/main.swift`.

## Key entry points

- `GameController(assets:)` → owns boot flow.
- `ScenarioScene(assets:scenarioName:)` → build → tick loop.
- `BuildPanelController.handle(click:)` → `Action`.
- `UnitCommandController.handle(click:pool:playerHouseID:)` → `Action`.

## Testing

Scene-level visual correctness can't be asserted from CI (sandbox can't drive SpriteKit). Controllers are fully unit-tested in `Core/Tests/DuneIICoreTests/{BuildPanelTests,UnitCommandControllerTests}.swift`. Visual checks land as manual-verification checklists in the algorithm doc for the relevant slice.
