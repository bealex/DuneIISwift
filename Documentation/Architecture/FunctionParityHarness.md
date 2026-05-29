# Function-parity harness

How we port the native functions the EMC scripts call and prove each one is bit-identical to OpenDUNE, **before** transcribing the EMC bytecode itself. This is the operational doc for the Tier-1 / Tier-2a layers of `ParityHarness.md`; it complements `TickParityHarness.md` (whole-tick state dumps), reusing the same headless OpenDUNE build.

## The three steps (the plan of record for this phase)

1. **Port the native functions the EMC needs.** The EMC bytecode does nothing but stack manipulation plus calls into a fixed table of native functions (`Emc.unitFunctions` / `structureFunctions` / `teamFunctions`, mirroring OpenDUNE `g_scriptFunctions{Unit,Structure,Team}`, `script/script.c:42-159`). Those native functions — and the primitives they call (`Tools_*`, `Tile_*`, pool/`Unit`/`Structure`/`House` accessors) — are the port surface. Port them bottom-up.
2. **Match-test every ported function against OpenDUNE.** For each function, OpenDUNE emits a golden fixture of `(input → output)` records; the Swift port asserts bit-exact equality. A function is "done" only when its golden test is green.
3. **Port the EMC files.** Once the primitives match, transcribe `UNIT/BUILD/TEAM.EMC` into hand-written Swift state machines (exact logical transcription — decision #3), verified by per-object decision-trace equivalence (Tier 2a) against the same OpenDUNE oracle.

## The oracle: headless OpenDUNE

OpenDUNE under `Repositories/OpenDUNE/` builds headlessly on this machine (Apple Silicon, clang) against Homebrew SDL2 via a tiny shim:

```sh
cd Repositories/OpenDUNE
PATH="$PWD/.shim:$PATH" ./configure --with-sdl2="$PWD/.shim/sdl2-config"
PATH="$PWD/.shim:$PATH" make -j4          # -> ./bin/opendune
```

`.shim/sdl2-config` forwards to the Homebrew one; parity mode forces the SDL `dummy` video driver, so no window/display/audio is needed. The patch is additive and gated entirely behind `--parity-*` flags — vanilla OpenDUNE behaviour is unchanged when no flag is given. (The OpenDUNE tree is an external reference with its own git; these patches live uncommitted in its working tree. Only the *generated fixtures* are committed to our repo.)

## Golden fixtures (Tier 1 — pure functions)

`opendune --parity-golden=<dir>` (`src/parity.c:Parity_DumpGolden`, wired in `main()` before any install/PAK init) writes **one JSONL fixture per category** into `<dir>` — `rng-golden.jsonl`, `tile-golden.jsonl`, … — each a list of JSON objects (one per line) of bit-exact outputs over a fixed input grid, then `exit(0)`. No save, PAK, or install is required. Add a category by writing a `Golden_<Category>(FILE *)` and one entry in the `categories[]` table.

Record shape (one example per category):

```json
{"fn":"Tools_RandomLCG_Range","seed":0,"min":0,"max":32767,"out":[ …64 values… ]}
{"fn":"Tile_GetDirection","from":[128,128],"to":[384,640],"out":109}
```

Fixtures are **committed** under `Code/Tests/<Subject>Tests/Fixtures/`, one file per category. The shared `WorldTests/GoldenFixture` loader locates a file via `#filePath` (same pattern as `FormatsTests/TestInstall`), parses each line into a superset `Record` (all fields but `fn`/`out` optional; `out`/`from`/`to` may be scalar or array), and filters by `fn`; each golden test re-seeds the Swift port and asserts every output matches. `Fixtures/` is `exclude:`d from the test target's build graph (read from the source tree, not bundled). Widening coverage = add inputs to the category's `Golden_*` fn, rebuild, re-run the flag, recommit that fixture.

When a primitive is pure-ish but reads one or two globals (e.g. `Tools_AdjustToGameSpeed` reads `g_gameConfig.gameSpeed`), the dumper sets those globals across their meaningful range and tags each record with them — still self-contained.

## Decision traces (Tier 2a — World-dependent functions)

Most script functions (see the dependency classification below) touch `GameState` — the unit/structure/house pools, the map, fog, spice. They can't be golden-dumped in isolation; they are verified by **per-object decision-trace equivalence** using the already-present hooks: `--parity-script-trace` + `--parity-script-unit/-structure` (`script/script.c`), `--parity-random-trace`, `--parity-lcg-trace`, and the whole-tick state dump (`TickParityHarness.md`). We load a small save, single-step one object, and assert our state machine requests the same primitives in the same order with the same arguments and the same resulting `ScriptEngine` variable changes. This is step 3's verification and arrives with the EMC transcription, not before.

## Port order (bottom-up, by dependency tier)

Driven by the dependency classification of the script-function tables:

- **Tier 0 — zero-dependency primitives (golden-testable now).** Both RNGs (`Tools_Random_256`, `Tools_RandomLCG`/`_Range`) ✅; `Tools_AdjustToGameSpeed`; `Tile_*` geometry (`Tile_GetDistance`, pack/unpack, `Tile_GetDirection`); `Tools_Index_Encode/Decode/GetType` (encoding math, minus the pool-validity check). The `General_*` near-pure script ops are thin wrappers over these: `General_Delay` (`/5`), `General_DelayRandom` (`Tools_Random_256 * n / 256 / 5`), `General_RandomRange` (`Tools_RandomLCG_Range`), `General_NoOperation`.
- **Tier 1 — the World model.** `Unit`/`Structure`/`House`/`Team` PODs, the object pools, and the static stat tables (`table/*info.c` → Swift `let`). Prerequisite for everything below; this is the bulk of Phase 2.
- **Tier 2 — World-dependent script functions.** Everything in the three tables: getters (`Unit_GetInfo`, `Structure_GetState`, `General_GetOrientation`, …), then mutators/algorithms (`Unit_SetAction`, `Unit_CalculateRoute` (A*), `Unit_Fire`, `Structure_Fire`, targeting, harvest, fog). Verified by Tier-2a traces.
- **Tier 3 — the EMC state machines.** Transcribe per-type bytecode using the disassembler listings, calling the now-verified primitives.

## Status

- ✅ Headless OpenDUNE oracle builds; `--parity-golden=<dir>` mode added (one fixture per category under `Code/Tests/WorldTests/Fixtures/`, loaded by `WorldTests/GoldenFixture`).
- ✅ `Tools_Random_256` and `Tools_RandomLCG`/`_Range` ported (`DuneIIWorld/Rng/`), golden-verified (`WorldTests/RngGoldenTests`).
- ✅ Tile geometry + orientation: `Tile32` (unpack/pack, `GetDistance`/`Packed`/`RoundedUp`, `GetDirection`/`Packed`) and `Orientation.to8`/`to16` (`DuneIIWorld/Tile/`), golden-verified (`WorldTests/TileGoldenTests`). See `Algorithms/Tile.md`.
- ✅ `Tools_AdjustToGameSpeed` (game-speed param) and `Tools_Index_GetType`/`Decode` (`DuneIIWorld/Tools/`), golden-verified (`WorldTests/ToolsGoldenTests`). See `Algorithms/Tools.md`.
- ✅ Static stat tables (begun): `HouseInfo`, `LandscapeInfo`, `ActionInfo` (`DuneIIWorld/Stats/`) + `HouseID` (Contracts) and `LandscapeType`/`MovementType`/`ActionType`/`SelectionType` (World), golden-verified (`WorldTests/{HouseInfo,StatTable}GoldenTests`). See `Algorithms/StatTables.md`.
- ⏭ Next: the big tables — `ObjectInfo` + `UnitInfo` (`unitinfo.c`) and `StructureInfo` (`structureinfo.c`), with `UnitType`/`StructureType` seam enums; then `Unit`/`Structure`/`House` PODs + object pools + `GameState`. That unlocks the deferred pool-dependent primitives (`Tools_Index_Encode`/`IsValid`/`Get*`) and the World-dependent script functions.
