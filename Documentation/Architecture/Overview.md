# Architecture overview

The living architecture reference. For goals, locked decisions, and the phased build see `../Plan.v1.md` (the plan of record). For the parity methodology see `ParityHarness.md`; for the testing strategy see `Testing.md`.

## Shape

The **simulation** is the center; **renderer / input / audio** are mockable leaves that depend only on `DuneIIContracts`, never on each other, and the simulation depends on none of them. All mutable simulation state lives in one owned `GameState`. This is the seam OpenDUNE's `parity.c` already proves works (it runs the four `GameLoop_*` functions headless, with no rendering/input/audio).

## Targets and dependencies (downward only)

```
 Hosts:  duneii (native macOS app)           duneii-headless (tests/oracle)
            └───────── wire the pieces together ──────────┘
   ┌───────────┬───────────┬───────────┬────────────────────────────┐
   │ Renderer  │  Input    │  Audio    │  Simulation (logic + loop)  │
   │ FrameInfo │  Command  │ SoundEvent│  primitives + state machines│
   │  → pixels │  ← input  │  → audio  │  + four-phase tick()        │
   └────┬──────┴─────┬─────┴─────┬─────┴──────────────┬─────────────┘
        │            │           │                    │
        └────────────┴─────┬─────┴────────────────────┘
                           ▼
                 ┌────────────────────┐
                 │ Contracts          │  FrameInfo · Command · SoundEvent · IDs
                 ├────────────────────┤
                 │ World + GameState  │  model, pools, stat tables, RNG, clocks;
                 │  + Save/Load + conv │  scenario load; our + original saves
                 ├────────────────────┤
                 │ Formats / Codecs   │  PAK SHP WSA CPS ICN FNT VOC INI SAVE EMC
                 └────────────────────┘  Format80/40 (pure Data→Data)
```

`DuneIIRenderer`/`Input`/`Audio` ship a protocol + a Foundation-only Null/Mock implementation plus the real one: `SpriteKitRenderer`, the `InputController`, and `EngineAudioSink` (AVAudioEngine). The `duneii` host is a **native macOS** (AppKit + SwiftUI, non-Catalyst) app — a SwiftUI map window + floating `NSPanel` tool windows.

## What mirrors OpenDUNE, what departs

**Mirrors:** the four-phase tick (Team → Unit → Structure → House); the object-pool model (fixed arrays + dense find-index) and encoded indices; the `Object`/`ObjectInfo` base split; seed-derived maps; the stat-table contents.

**Departs (deliberately, for extensibility/testability):** all global mutable state collapses into one owned `GameState`; render/input/audio become contract-bounded leaves; behavior becomes exact-transcription state machines instead of an EMC bytecode VM; the renderer is a pure function of a `FrameInfo` snapshot.

## OpenDUNE constraints we must honor

Verified facts from `Repositories/OpenDUNE/`. Requirements, not suggestions.

- **Canonical headless tick** = `{ timerGame++; timerGUI++; GameLoop_Team(); GameLoop_Unit(); GameLoop_Structure(); GameLoop_House(); }` (`parity.c:372-382`).
- **Two independently-gateable clocks** — `timerGame` (gameplay) and `timerGUI` (presentation cadence). **Pause is a clock gate** (stop GAME, keep GUI), not a loop stop.
- **Game speed reshapes inter-action intervals** (`Tools_AdjustToGameSpeed`, `tools.c:20`), it is not a clock multiplier. Test speed-up = run ticks back-to-back at a fixed `gameSpeed`.
- **Per-subsystem cadences** (unit movement 3, scripts 5, AI teams jittered 5–12, structures ~30, houses 900) live in tick cursors that must become per-instance `GameState` fields.
- **Stat tables are hardcoded C** (`table/*info.c`) — port as Swift `let`. Only EMC bytecode, scenario `.INI`, and saves are read at runtime. `ObjectInfo.available` is mutable runtime state hiding in the "static" table — hoist it into `GameState`.
- **Save format** = IFF/FORM chunk container + descriptor-driven serializer; the map is regenerated from a seed then patched; the RNG seed is not saved by the original (we save ours).
- **Two RNGs** must be bit-exact: `Tools_Random_256` (`tools.c:268`) and a Borland LCG (`tools.c:327`).
- **The render path mutates the sim** (`GUI_DrawScreen` runs `Explosion_Tick`/`Animation_Tick`/`Unit_Sort`) — move gameplay effects into the sim tick so the renderer is read-only over a `FrameInfo` snapshot. Explosion damage is already on the game clock (`Map_MakeExplosion`, `map.c:403`).
- **Sound is fired inline** from sim logic — emit `SoundEvent`s instead.
- **Input mutates the sim directly** — translate input to `Command`s applied between ticks.
- **Behavior is script-driven and co-routined** — logic and loop are one package; state machines are transcribed from the disassembled EMC, never invented.
- **Pin compatibility flags:** `g_dune2_enhanced = false` (the 1.07 path); fixed `gameSpeed` for comparisons.

The compact `file:line` porting reference lives in `../Plan.v1.md` (appendix).
