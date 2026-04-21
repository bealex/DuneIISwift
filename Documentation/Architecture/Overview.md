# Architecture Overview

Status: Draft · Updated 2026-04-19 (P1 kickoff)

This document describes the module layout and threading model of the Dune II remake. Scope: macOS 26, Apple Silicon, Swift 6.3.1, Mac Catalyst + SpriteKit.

See `Documentation/Plans/01.Initial.md` §4 for the directory skeleton — this doc explains the *why* behind it.

## 1. Module graph

```
                ┌──────────────────────────────┐
                │            App               │  UIKit app target
                │  (Catalyst UIApplication)    │
                └──────────────┬───────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
      ┌──────────┐     ┌──────────────┐    ┌──────────┐
      │    UI    │     │  Rendering   │    │  Audio   │
      │ (UIKit)  │     │ (SpriteKit)  │    │ (AVF)    │
      └────┬─────┘     └──────┬───────┘    └────┬─────┘
           │                  │                 │
           └──────────┬───────┴─────────────────┘
                      ▼
              ┌───────────────┐
              │   Platform    │  macOS integrations
              └───────┬───────┘  (file pickers, menus, prefs)
                      │
                      ▼
              ┌───────────────┐
              │     Core      │  pure-Swift, no UIKit/SpriteKit
              │  Formats      │
              │  Codec        │
              │  Simulation   │
              │  Scripting    │
              │  AI           │
              │  Save         │
              └───────────────┘
```

**Core** is a SwiftPM package with zero platform dependencies — it only uses `Foundation` and `Synchronization`. It can be built and tested headless, which is the entire P1 deliverable.

Everything above Core depends on Core but Core never reaches up. UI does not import Rendering; Rendering does not import UI. They communicate through message types defined in Core (`GameCommand`, `GameEvent`).

## 2. Threading model

Three long-lived concurrency domains:

| Domain        | Isolation                          | Owns                                            |
|---------------|------------------------------------|-------------------------------------------------|
| `@MainActor`  | main thread                        | UIKit, SpriteKit scenes, input, window          |
| `GameActor`   | dedicated actor                    | simulation state (pools, map, scripts, AI)     |
| asset decode  | `Task { … }` on the global pool    | one-shot: PAK open, ICN/SHP → atlas, VOC → PCM |

The simulation tick runs on `GameActor` at the original Dune II rate (roughly 20 Hz — exact value pinned once we instrument OpenDUNE's `opendune.c`). `GameActor` emits `GameEvent`s; the main actor consumes them via an `AsyncStream` and drives SpriteKit. The main actor posts `GameCommand`s into a bounded queue that the simulation actor drains at the start of each tick.

This means: **no locks** in the simulation. Actor isolation enforces single-writer access; `Sendable` conformances are real (no `@unchecked Sendable`, no `nonisolated(unsafe)`). The only exception is the tick clock, which uses `Mutex` from `Synchronization` to schedule the next tick deadline — it's touched from a `DispatchSourceTimer` and by the actor.

## 3. Data flow — asset load to first frame

1. **Launch** — main actor opens `Repositories/patched_107_unofficial/` (dev) or the bundled `Resources/Original/` (ship).
2. **PAK index** — `Formats.Pak.Archive.open(_:)` memory-maps each PAK and returns a list of `(name, range)` entries. No decoding yet.
3. **Atlas build** — a background `TaskGroup` decodes every ICN file through `Codec.Format80` and packs the resulting 16×16 tiles into a single `SKTextureAtlas`. Cached to `~/Library/Caches/DuneIIRemake/atlas/` keyed by a content hash.
4. **Palette** — `Formats.Palette` reads `IBM.PAL` (6-bit VGA, 256×3 bytes) into a 256-entry `[UInt32]` (RGBA8). Palette cycling animations (mentat static, lava, etc.) are driven by the render loop, not the simulation.
5. **Scene swap** — the main actor installs the `MainMenu` `SKScene` and starts the intro WSA via `Formats.Wsa.Animation`.

## 4. Simulation tick

Each tick the `GameActor`:

1. Drains the command queue (user input translated to game commands).
2. Advances the map (spice bloom timers, sandworm movement).
3. Runs one EMC step per active structure and unit.
4. Runs one team-AI step per AI house.
5. Applies pending damage, births, deaths.
6. Emits `GameEvent`s (sprite updates, sounds to cue, HUD diffs).

This matches OpenDUNE's `GameLoop_Main` structure — the order is load-bearing because unit scripts read structure state set earlier in the same tick.

## 5. Rendering

SpriteKit is used as a thin sprite compositor, not a physics/particle engine:

- One `SKScene` per top-level game screen (Intro, MainMenu, Mentat, Region, Game, GameOver).
- The **Game** scene holds three `SKNode` layers: terrain (baked), objects (dynamic sprites for units/structures/projectiles), and overlay (fog, selection rects, build placement preview).
- The terrain layer is pre-rendered to an off-screen texture when the map loads and only re-drawn when a tile mutates (spice delta, wall damage, crater). This avoids per-frame cost of a 64×64 `SKSpriteNode` grid.
- All textures use `.nearest` filtering and integer scaling.

## 6. Audio

`Audio/` wraps AVFoundation:

- VOC samples decoded to `AVAudioPCMBuffer` at load time, played via `AVAudioPlayerNode` on a shared `AVAudioEngine`.
- XMI / C55 converted to Standard MIDI Files once and played via `AVMIDIPlayer` with a bundled SoundFont (see `Resources/Audio/SoundFont/`). ADL support is deferred — risk §5 in the plan.

## 7. Save/Load flow

```
┌───────────────┐   classic .DAT   ┌──────────────────────┐
│  GameActor    │ ───── encode ──▶ │ Core.Save.ClassicDat │──▶ file
│  (state)      │ ◀──── decode ─── │                      │
└───────────────┘                  └──────────────────────┘
         │                                    │
         │   native wrapper (P6+)             │
         ▼                                    ▼
┌───────────────┐                  ┌──────────────────────┐
│ Save.Native   │ embeds classic   │  NSSavePanel flow    │
│   (thumbnail, │      blob        │   via Catalyst       │
│   metadata)   │                  │                      │
└───────────────┘                  └──────────────────────┘
```

Reading a 1.07 `_SAVE00?.DAT`: the IFF-style chunk walker produces a typed `Save.Snapshot`, which `GameActor` swaps in wholesale. Writing: the snapshot is re-encoded chunk-by-chunk, preserving any opaque chunks verbatim (risk §4 in the plan).

## 8. Testing surfaces

- `Core/Tests/FormatsTests/` — per-format round trips using small fixtures checked into `Core/Tests/Fixtures/`.
- `Core/Tests/CodecTests/` — format80/format40 decode against known-good outputs produced by the OpenDUNE decoder (compiled and run once, results frozen).
- `Core/Tests/SimulationTests/` — golden tick tests (arrives in P4).
- `Core/Tests/SaveTests/` — round-trip the seven user saves (P6).

## 9. Open architectural questions

Tracked in `01.Initial.md` §10. The two that touch this architecture directly:

- **Catalyst menu bar**: SpriteKit-owning `UIView` may need a thin AppKit bridge for correct menu bar ownership. Decided in P2 when we need File → Open.
- **ADL synth**: if we ship ADL playback, it needs its own `AVAudioSourceNode` driving an OPL emulator. That would add a module under `Audio/OPL/`.
