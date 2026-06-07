# Dune II — Swift

A **research project** reimplementing Westwood's *Dune II: The Building of a Dynasty* (v1.07) as a
modern, native **Swift** game engine for **macOS and iOS** (Apple Silicon). The goal is a faithful,
well-tested re-creation of the original's behaviour and graphics — not a remaster or a new game.

> ⚠️ **This is an experiment / study project.** It is not affiliated with or endorsed by Westwood
> Studios, Electronic Arts, or the OpenDUNE project. It ships **no** game data of any kind.
>
> 🍎 **macOS / iOS only.** It is built on the Apple toolchain (SwiftUI, SpriteKit, AppKit/UIKit) by
> design — there is **no Windows or Linux build**.

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

- **macOS 26 on Apple Silicon**, with Xcode and the Swift 6.3.2 toolchain. (macOS / iOS only — no
  Windows or Linux build.)
- A legitimate **Dune II 1.07** install — the `*.PAK` data files (see *Game data* below).
- For the **iOS** client: `xcodegen` (`brew install xcodegen`).
- For cross-engine parity work (optional): a local clone of [**OpenDUNE**](https://github.com/OpenDUNE/OpenDUNE)
  (the reference/oracle) and, optionally, [**dunepak**](https://github.com/Will40/dunepak) (a PAK
  packer/unpacker). External projects, referenced — not vendored. See `Documentation/Architecture/`.

## Game data

You must supply your own **Dune II 1.07** install — the `*.PAK` files (`DUNE.PAK`, `ENGLISH.PAK`,
`SCENARIO.PAK`, `VOC.PAK`, …). Nothing game-related is committed in this repository.

**Place the install** at `Repositories/patched_107_unofficial/` (the default the app and scripts look for),
so that directory contains the `*.PAK` files directly:

```
Repositories/patched_107_unofficial/
   DUNE.PAK   ENGLISH.PAK   SCENARIO.PAK   VOC.PAK   …
```

…or keep it elsewhere and point at it with the `DUNEII_INSTALL=/path/to/dune2` environment variable (the
scripts), or by passing the path as the first argument to the macOS app.

The engine reads these PAKs **directly** — that's all you need to run the game. A decoded, git-ignored
`Resources/` tree (sprites/tiles/scripts/audio as PNG/WAV/text) is **optional**; it's produced from the
install for the tests and verification tools, and is where the in-game music is read from:

```sh
cd Code
swift run assetgen extract ../Repositories/patched_107_unofficial ../Resources
swift run assetgen emc-disasm   # (optional) disassemble UNIT/BUILD/TEAM.EMC
```

Tests that need real data short-circuit cleanly when `Resources/` is absent; the game runs without it (just
without music).

## Build & run

The package lives under `Code/` (SwiftPM). `Scripts/check.sh` wraps this repo's environment quirks
(repo-local `TMPDIR`, sandbox flags, the OpenDUNE oracle build) and is the preferred way to build + test:

```sh
Scripts/check.sh            # incremental build + full test suite (concise pass/fail summary)
Scripts/check.sh --full     # clean build + zero-warnings audit
```

### macOS app

With the install in place (see *Game data*):

```sh
cd Code
swift run duneii            # launch the macOS game client (reads the PAKs from your install)
```

`swift build` / `swift test` build the libraries + CLI tools and run the full suite.

### iOS app

The iOS deploy uses **XcodeGen** (no committed `.xcodeproj`). Personal identifiers live in a git-ignored
`.env` — copy `.env.example` to `.env` and set your device + Apple Developer team for on-device builds:

```sh
cp .env.example .env        # then set DUNEII_DEVICE (UDID or name) and DUNEII_TEAM (for signing)

Scripts/build-ios.sh sim                 # build + install + launch on the iOS Simulator (no signing)
Scripts/build-ios.sh device              # … on the first connected iPhone/iPad (or DUNEII_DEVICE)
Scripts/build-ios.sh device "<name|UDID>"  # … on a specific device
Scripts/build-ios.sh archive             # Release archive + signed .ipa (TestFlight / Ad-Hoc)
```

The script stages the install PAKs into the app, runs `xcodegen`, then `xcodebuild`. The **Simulator** path
needs no signing; **device**/**archive** need your Apple ID for `DUNEII_TEAM` logged into Xcode (automatic
signing). See `Code/Apps/duneii-ios/README.md` for details.

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

## Other Dune II reimplementations

This is far from the only effort to keep *Dune II* alive — worth a look, and credit to all of them:

- **[OpenDUNE](https://github.com/OpenDUNE/OpenDUNE)** — the reverse-engineered C engine (GPL-2.0) this
  project ports from and verifies against.
- **[Dune Dynasty](https://github.com/gameflorist/dunedynasty)** — a remaster/enhancement built on the
  reverse-engineered engine, with modern conveniences; Windows/macOS/Linux.
- **[Dune Legacy](https://dunelegacy.com/)** — an SDL-based open-source remake (higher resolutions, smarter
  controls, multiplayer).
- **[Dune II — The Maker (D2TM)](https://github.com/stefanhendriks/Dune-II---The-Maker)** — a long-running
  remake with zoom, multi-select, skirmish, and higher resolutions.
- **[Dune2JS](https://github.com/oklemenz/Dune2JS)** — a Dune II reimplementation in HTML5 / JavaScript.

(This project's distinct angle: a behaviorally **bit-faithful** Swift port, cross-verified against OpenDUNE,
rather than a remaster — see above.)

## License

This project is a **faithful port of [OpenDUNE](https://github.com/OpenDUNE/OpenDUNE)** — its simulation
primitives, scripting state machines, stat tables, and codecs are exact transcriptions of OpenDUNE's C
source. OpenDUNE is licensed under the **GNU General Public License, version 2.0**, so this derivative work
is likewise licensed under **GPL-2.0** — see the [`LICENSE`](LICENSE) file for the full text.

The FM-music dependency [SwiftOPL3](https://github.com/bealex/SwiftOLP3) is LGPL-2.1, which is
GPL-compatible.

**No *Dune II* game data is covered by this license.** The original game, its assets, and trademarks remain
the property of their respective rights holders (Westwood Studios / Electronic Arts) and are **not**
distributed here — you must supply your own copy of Dune II 1.07.
