# DuneIIClient

The shared **app layer** for the platform game clients — the macOS `duneii` app and the iOS `duneii-ios` app. Everything both clients have in common lives here so there is no duplication; only the per-platform shells (the `@main App`, the root `ContentView` window/toolbar chrome, file dialogs) sit above it in the app targets.

Contents:
- `GameModel` — the `@MainActor @Observable` aggregate the UI binds to: owns the `Simulation`, the `Viewport` camera, selection/build/economy/scenario state, and the per-frame loop. Platform-agnostic.
- `AssetStore` — loads the original install's PAKs (`ICON.ICN`/`ICON.MAP`/`IBM.PAL`/`UNITS*.SHP`/scenario INIs/VOC). On macOS it points at the install dir; on iOS the app points it at the bundled PAKs.
- `GameScene` — the SpriteKit map renderer + camera. Rendering is cross-platform (`SKColor`); **input is conditionally compiled**: `#if os(macOS)` `NSEvent` mouse/keyboard handlers, `#if os(iOS)` touch + gesture handlers. Both paths convert to a tile and call the same `GameModel` commands.
- The SwiftUI verification UI — `GameSidebar` (the in-game info column), `Panels` (Inspector/Economy/Debug), `Minimap`, `ScenarioPicker`, `Settings` — all cross-platform SwiftUI.

Depends on the engine libraries (Contracts/Formats/World/Simulation/Renderer/Input/Audio); imports SwiftUI + SpriteKit, and AppKit/UIKit only behind `#if os(...)`. Never depended on by the engine.

Dependency rule: this is a presentation/app layer — the simulation does **not** depend on it. Keep platform specifics behind `#if os(macOS)` / `#if os(iOS)`; do not let one platform's API leak into shared code.
