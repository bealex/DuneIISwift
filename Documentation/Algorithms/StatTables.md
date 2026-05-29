# Static stat tables

Dune II's per-type constants live in **hardcoded C tables** (`src/table/*info.c`), not on disk — so they are ported as Swift `let`s in `DuneIIWorld/Stats/`, one struct + `table` array per OpenDUNE `g_table_*`. `ObjectInfo.available` and a few other "static" fields are actually mutable runtime state and will be hoisted into `GameState` when those tables land; the pure-constant tables below are plain `let`s.

Each table is **golden-verified field-for-field** against the oracle: `opendune --parity-golden=<dir>` dumps one `<name>-golden.jsonl` per table (one JSON object per entry), and the Swift test asserts every field of every entry. A transcription typo fails the test. See `../Architecture/FunctionParityHarness.md`.

## Ported so far

- **`HouseInfo`** (`house.h` / `houseinfo.c`) — keyed by `HouseID` (Contracts). Per-house toughness, degrading chance/amount, minimap colour, special-weapon countdown + type, starport delivery time, filename prefix char, win/lose/briefing music, voice file. Fixture `houseinfo-golden.jsonl`, suite `HouseInfoGoldenTests`.
- **`LandscapeInfo`** (`map.h` / `landscapeinfo.c`) — keyed by `LandscapeType` (15). `movementSpeed[MovementType]` (6), wobble/build-validity/sand/spice flags, crater type, radar colour, sprite id. Fixture `landscapeinfo-golden.jsonl`, suite `StatTableGoldenTests`.
- **`ActionInfo`** (`unit.h` / `actioninfo.c`) — keyed by `ActionType` (14). String id, name, switch type (queue/immediate/subroutine), `SelectionType`, foot-unit sound id. Fixture `actioninfo-golden.jsonl`, suite `StatTableGoldenTests`.

Supporting enums introduced with these: `HouseID` (Contracts); `LandscapeType`, `MovementType`, `ActionType`, `SelectionType` (World).

## Not yet ported (next chunks)

- **`ObjectInfo` + `UnitInfo`** (`unitinfo.c`, ~27 units) and **`StructureInfo`** (`structureinfo.c`) — the large tables, with the 13-bit `ObjectInfo.flags` bitfield. Their own dedicated chunk(s); `UnitType`/`StructureType` seam enums land with them. These unlock `Script_Unit_GetInfo`, build costs/times, hitpoints, the structure layouts (currently mirrored ad-hoc in `DuneIIRenderer.StructureCatalog`), etc.
- Smaller tables as needed: movement-type names, damage/explosion/animation tables, team actions.
