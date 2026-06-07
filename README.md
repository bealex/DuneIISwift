# Dune II — Swift

A **research project** reimplementing Westwood's *Dune II: The Building of a Dynasty* (v1.07) as a
modern, native **Swift** game engine for macOS (Apple Silicon). The goal is a faithful, well-tested
re-creation of the original's behaviour and graphics — not a remaster or a new game.

> ⚠️ **This is an experiment / study project.** It is not affiliated with or endorsed by Westwood
> Studios, Electronic Arts, or the OpenDUNE project. It ships **no** game data of any kind.

## What it is

- **Behaviorally faithful.** The simulation is verified to be bit-identical to [OpenDUNE](https://github.com/OpenDUNE/OpenDUNE)
  (the open-source C reimplementation of Dune II) wherever behaviour is deterministic, and within
  OpenDUNE's own seed-to-seed spread wherever it is stochastic. OpenDUNE is used as the **oracle** for
  every game-logic primitive, stat table, codec, and the save format.
- **Pixel-faithful graphics.** Asset decoders (PAK/SHP/WSA/CPS/ICN/PAL/VOC) and the renderer reproduce
  the original's pixels exactly; render output is checked against pixel-exact goldens.
- **Headless & deterministic.** The core engine runs with no renderer, input, or audio for fast,
  repeatable, sped-up testing. Same scenario + seed + command stream ⇒ byte-identical run, every time.
- **Our own UI.** The project does **not** reproduce the original menus, intros, cutscenes, or HUD — the
  interactive client is a small native macOS/iOS verification UI (SwiftUI + SpriteKit) over the engine.

It is written in Swift 6.3.2 with strict concurrency, targeting macOS 26. The engine libraries are
Foundation-only; the renderer uses SpriteKit; the app host is a native AppKit + SwiftUI app
(non-Catalyst). There is also an iOS client that shares the same engine.

## Legal / game data

Dune II and its assets are the property of their respective rights holders. **No original game files,
extracted assets, or save games are included in this repository**, and you must own a legitimate copy of
Dune II 1.07 to build a runnable game.

At build time the engine reads from a local copy of the original 1.07 install (never committed) and the
runnable `Resources/` are **generated locally** from it (see *Game assets* below) — they are not stored
in version control.

## Requirements

- macOS 26 on Apple Silicon, with Xcode and the Swift 6.3.2 toolchain.
- A legitimate **Dune II 1.07** install (the `*.PAK` data files), placed where the tools can read it.
- For cross-engine parity work: a local clone of [**OpenDUNE**](https://github.com/OpenDUNE/OpenDUNE) (the
  reference/oracle) and, optionally, [**dunepak**](https://github.com/Will40/dunepak) (a PAK packer/unpacker).
  These are external projects, referenced — not vendored here. See `Documentation/Architecture/` for how they
  are wired into the parity harness.
- For the iOS client: `xcodegen` (`brew install xcodegen`).

## Game assets (generated, not committed)

The decoded `Resources/` tree (sprites, tiles, palettes, scripts, audio) is produced from your install by
the asset extractor and is git-ignored:

```sh
cd Code
swift run assetgen            # extract Resources/ from the Dune II install
swift run assetgen emc-disasm # (optional) disassemble UNIT/BUILD/TEAM.EMC
```

Point the tools at your install via the `DUNEII_INSTALL` environment variable (or the default path used by
the scripts). Tests that need real data short-circuit cleanly when the assets are absent.

## Build & run

The package lives under `Code/` (SwiftPM). The `Scripts/` directory wraps this repo's environment quirks
(repo-local `TMPDIR`, sandbox flags, the OpenDUNE oracle build) and is the preferred entry point:

```sh
Scripts/check.sh            # incremental build + full test suite (concise pass/fail summary)
Scripts/check.sh --full     # clean build + zero-warnings audit
```

Raw SwiftPM also works:

```sh
cd Code
swift build                 # libraries + CLI tools
swift test                  # the full suite
swift run duneii            # the macOS game client (needs Resources/ generated first)
```

iOS:

```sh
Scripts/build-ios.sh sim       # build + run on the iOS Simulator
Scripts/build-ios.sh device    # build + install on a connected device
```

## Repository layout

- `Code/` — the SwiftPM package:
  - `Frameworks/` — the engine libraries (`DuneIIContracts`, `DuneIIFormats`, `DuneIIWorld`,
    `DuneIISimulation`, `DuneIIRenderer`, `DuneIIInput`, `DuneIIAudio`, `DuneIIExport`, `DuneIIClient`).
    Dependencies point downward only; the simulation depends on no presentation leaf.
  - `Apps/` — runnable end-products: `duneii` (macOS client), `duneii-ios` (iOS client), plus headless
    drivers and verification viewers.
  - `Tools/` — developer/build tools (`assetgen`, the EMC disassembler).
  - `Tests/` — one test target per engine target.
- `Documentation/` — the plan of record, architecture, on-disk format notes, algorithms, the parity
  harness, a dated changelog (`History/`), and distilled insights.
- `CurrentState.md` — the operational resume point (active task, next steps, test status).

## Testing & parity

Every format, codec, and native primitive ships with tests. Gameplay/parity features are verified by
**cross-engine scenario goldens** (the Swift engine's event/RNG trace aligned against OpenDUNE),
structure-decision traces (opcode-identical EMC), and **render goldens** (pixel-exact). See
`Documentation/Architecture/Testing.md` and `ParityHarness.md`.

## Related projects

- **[OpenDUNE](https://github.com/OpenDUNE/OpenDUNE)** (GPL-2.0) — the open-source C reimplementation of
  Dune II; this project's behavioural **oracle** and the source it ports from.
- **[dunepak](https://github.com/Will40/dunepak)** — a Dune II PAK file packer/unpacker; the reference for
  the PAK asset-container format.
- **[SwiftOPL3](https://github.com/bealex/SwiftOLP3)** (LGPL-2.1) — a pure-Swift OPL3/YMF262 FM synth +
  Westwood `.ADL` driver; this project's AdLib-music backend (a SwiftPM dependency, not vendored).

## License

This project is a **faithful port of [OpenDUNE](https://github.com/OpenDUNE/OpenDUNE)** — its simulation
primitives, scripting state machines, stat tables, and codecs are exact transcriptions of OpenDUNE's C
source. OpenDUNE is licensed under the **GNU General Public License, version 2.0**, so this derivative work
is likewise licensed under **[GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)**.

The FM-music dependency [SwiftOPL3](https://github.com/bealex/SwiftOLP3) is LGPL-2.1, which is
GPL-compatible.

**No *Dune II* game data is covered by this license.** The original game, its assets, and trademarks remain
the property of their respective rights holders (Westwood Studios / Electronic Arts) and are **not**
distributed here — you must supply your own copy of Dune II 1.07.
