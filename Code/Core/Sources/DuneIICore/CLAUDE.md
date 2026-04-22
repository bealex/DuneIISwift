# DuneIICore — module context

Pure-Swift library: file-format decoders, codecs, RNG, map generator, scenario model, scripting VM, simulation pools and ticks. **Foundation + Synchronization only.** No ImageIO, no SpriteKit, no AppKit, no filesystem I/O. Decoders take `Data`; higher layers own disk access.

This is the load-bearing half of the project. OpenDUNE parity lives here.

## Layout

- `DuneIICore.swift` — empty root namespace enum (so `import DuneIICore` is sufficient; callers use `Formats.Pak.Archive`, `Simulation.UnitPool`, etc.).
- `Codec/` — compression codecs shared by multiple formats.
  - `Format80.swift` — LZ-ish codec used by CPS, SHP, WSA, ICN.
  - `Format40.swift` — XOR-delta codec used by WSA frames.
  - Both are pure `Data → Data` functions.
- `Formats/<Name>/` — one subdirectory per on-disk format. Each exposes a single top-level type (e.g. `Formats.Pak.Archive`, `Formats.Shp.FrameSet`, `Formats.Emc.Program`). Covered: PAK, PAL, CPS, SHP, WSA, ICN, FNT, VOC, INI, EMC, XMI, IconMap, Save (multi-chunk IFF walker + per-chunk decoders).
- `Map/` — 64×64 tile grid, landscape types, tile resolver, `Generator` (bit-for-bit port of `Map_CreateLandscape`).
- `RNG/RNG.swift` — `ToolsRandom256` and `BorlandLCG`, both pinned to OpenDUNE baselines.
- `Scenario/` — typed scenario model built over `Formats.Ini.Document` plus `ScenarioWorld` (stamped map + footprint queries).
- `Scripting/` — EMC virtual machine.
  - `Scripting.swift`: root namespace.
  - `Engine` + `VM` (`Scripting.swift`): stack-based 19-opcode interpreter, `Script_Run` port.
  - `EncodedIndex.swift`: 16-bit `{kind, index}` encoding (`Tools_Index_*` port).
  - `Host.swift`: reference-typed context (pools, currentObject, player house, text log, voice log, tile/landscape closures).
  - `Functions.swift` + `FunctionTables.swift`: 64-slot per-type function tables (unit / structure / team). Slots not yet ported stay `nil` with blocker-specific comments.
- `Simulation/` — game-state pools and per-tick driver.
  - Pools: `UnitPool` (102), `StructurePool` (82 hard / 79 soft + 3 reserved aggregate), `HousePool` (6), `TeamPool` (16), `ExplosionPool` (32).
  - Static data tables: `UnitInfo` (27 rows), `StructureInfo` (19 rows), `LandscapeInfo` (15 rows). Values ported verbatim from `src/table/*.c`.
  - Logic: `Units.swift` (creation, orders), `Structures.swift` (create, allocate, build validation, construction state machine, factory spawn), `Explosions.swift`, `TargetAcquisition.swift`, `Pathfinder.swift`, `House.swift`, `Orientation.swift`, `Scheduler.swift` (per-tick driver).
  - `WorldSnapshot.swift` — loader from either save-file or scenario spawn; single source of truth for initial pool + tile state.
- `Logging/Logger.swift` — `Log` facade compiled to no-op in release (`#if DEBUG`). Backends injected from rendering / executable layers.

## Conventions

- Swift 6.0, strict concurrency. `Sendable` everywhere. Value types by default; reference types (`Host`, `RandomSource`) only when mutation needs to span closure captures.
- Pool slots are value types (`StructureSlot`, `UnitSlot`, …) with `isUsed` / `isAllocated` flags. Adding a new field: add it to the slot, plumb through both `WorldSnapshot` init paths (scenario-based + save-based), default-initialize in the pool's `init`.
- Data tables under `Simulation/*Info.swift` are `lookup(_:)`-style static functions returning optional info. **Do not** change a ported value without citing the OpenDUNE source line — those numbers are the authoritative balance.
- Host functions (EMC) use `peek`, not `pop`. The EMC compiler emits `STACK_REWIND` after every call — popping inside a host function would double-consume. See `Documentation/Insights/scripting-host-fn-peek-not-pop.md`.
- New host-function factories live in `Scripting.Functions` as `makeXxx(host:source:)` closures. Wire them into `unitTable(host:source:)` / `structureTable` / `teamTable` in `FunctionTables.swift`.
- Every decoder has a `DecodeError` enum with one case per failure mode. Every case gets a test.

## Key entry points

- `Formats.Pak.Archive(data:)` — catalog-by-name.
- `Formats.Save.Game.decode(_:)` — full savegame → typed model.
- `Core.Map.Generator.generate(seed:)` — bit-exact landscape reproduction.
- `Simulation.WorldSnapshot.init(scenario:resolver:)` / `init(save:)` — live pool bootstrap.
- `Simulation.Scheduler.tick()` — one sim tick: 7-opcode budget per unit script, 3 per structure, plus explosion / bullet / fire-cooldown / team passes.
- `Scripting.VM.step(_:)` — one opcode, mirrors `Script_Run`.

## Testing

All tests land in `Core/Tests/DuneIICoreTests/` (same target). Real-data tests gate on `TestInstall.locate()`. Coverage bar lives in the root `CLAUDE.md`.
