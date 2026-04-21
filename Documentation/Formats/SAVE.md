# SAVE — `_SAVE00?.DAT`

Status: Documented 2026-04-20

Dune II persists a running game to `_SAVE000.DAT` … `_SAVE009.DAT` in the install directory. The format is an IFF-style `FORM` with a fixed set of big-endian chunks. Unlike the game's data PAKs (little-endian everywhere), save chunks carry big-endian lengths — the container matches the Amiga/Electronic Arts IFF convention.

This document covers the container tree and the per-chunk 4CCs. Individual chunk bodies (pool slot layouts, scenario state, script engine state) live alongside the pool and engine work — see `Architecture/Pools.md` and `Algorithms/EmcVM.md`. Those land as we port each chunk's loader.

References:

- OpenDUNE `src/load.c` · `Load_FindChunk` and `Load_Main` drive the reader.
- OpenDUNE `src/save.c` · `Save_Chunk` and `Save_Main` drive the writer.
- OpenDUNE `src/saveload/saveload.c` · the per-field `SaveLoadDesc` table walker used inside each chunk.
- Our decoder: `Formats.Save.Container` in `Code/Core/Sources/DuneIICore/Formats/Save/`.

## 1. File layout

```
offset 0   "FORM"             4 bytes, 4CC
offset 4   form size          u32 BE — bytes after offset 8, including "SCEN"
offset 8   "SCEN"             4 bytes, IFF FORM type tag (no length field)
offset 12  chunk 0 tag        4 bytes
offset 16  chunk 0 length     u32 BE
offset 20  chunk 0 body       `length` bytes
           (optional pad      1 byte, present iff `length` is odd)
           chunk 1 tag …
```

Every chunk is laid out identically: 4-byte ASCII tag, 4-byte big-endian length, body, optional pad byte. The pad keeps the next tag word-aligned but is not counted in the chunk length — readers and writers add `(length & 1)` separately.

The outer `FORM` length covers everything from offset 8 (the `SCEN` tag) to the end of the file, so `form_size == file_size - 8`. Readers that only need to walk chunks can ignore it.

`SCEN` is the IFF form-type field, not a chunk: it has no length and no body. It appears exactly once, right after the form size.

## 2. Chunk order

Writers emit chunks in a fixed sequence. Readers do not depend on order except for `INFO`, which must be decoded before the others because it carries the savegame version. OpenDUNE explicitly rewinds after finding `INFO` and re-walks from `SCEN` to load the rest.

| # | Tag    | Present in 1.07? | Body                                                                     |
|---|--------|------------------|--------------------------------------------------------------------------|
| 0 | `NAME` | yes              | ASCII savegame description (≤ 255 bytes, NUL-terminated).                |
| 1 | `INFO` | yes              | Scenario metadata. Starts with `u16 LE` savegame version.                |
| 2 | `PLYR` | yes              | House pool (6 × house record).                                           |
| 3 | `UNIT` | yes              | Unit pool (102 × unit record).                                           |
| 4 | `BLDG` | yes              | Structure pool (82 × structure record).                                  |
| 5 | `MAP ` | yes              | Tile grid (4096 × tile record). **Tag ends with a space.**               |
| 6 | `TEAM` | conditional      | AI team pool. Emitted only when the scenario defines teams.              |
| 7 | `ODUN` | **no**           | OpenDUNE-only extension: extra unit fields the 1.07 format didn't hold.  |

The original Dune II 1.07 saves in `patched_107_unofficial/_SAVE00?.DAT` contain the first six chunks only. `ODUN` is a fabrication of the OpenDUNE writer and never appears in vanilla saves. `TEAM` is gated on whether the running scenario has any AI teams allocated (our decoder must therefore treat it as optional, not assert it present).

Loaders tolerate unknown tags (`Load_Main` falls through to a warning and skips by length) so future versions can introduce new chunks without breaking readers.

## 3. Versioning (`INFO`)

The first two bytes of the `INFO` body are a little-endian savegame version word. Modern Dune II 1.07 writes `0x0290`; anything else means the save was produced by an earlier, incompatible build. OpenDUNE treats version-mismatched saves as "load scenario + house slot, then restart the battle" — it pulls the scenario/campaign IDs via `Info_LoadOld` and the human-player house via `House_LoadOld`, then forces `GM_RESTART`.

Our decoder surfaces the version so the caller can pick the right per-chunk path. The container itself is identical across versions — only the chunk bodies change.

## 4. Parser sketch

The top-level walker matches the one we already use for EMC (see `EMC.md` §1) with two differences: the outer FORM type is `SCEN` rather than `EMC `, and the inner tag is ASCII with spaces preserved (`"MAP "`). Concretely:

1. Assert bytes 0..4 are `"FORM"`. Read the u32 BE size but don't trust it for bounds — use the buffer length.
2. Assert bytes 8..12 are `"SCEN"`.
3. From offset 12, repeatedly read `{ u32 BE length, body[length] }` keyed by the preceding 4CC tag. Advance `length + (length & 1)` after each body to skip the pad.
4. Stop when fewer than 8 bytes remain.

Index chunks by their tag into a `[String: Data]`. Callers then decode each chunk with its own loader (`INFO` first, then the rest).

## 5. Test coverage

- `SaveTests.swift` synthesises a minimal `FORM` with two chunks (one even, one odd length) and asserts round-trip plus pad-byte handling.
- A real-data test pulls `_SAVE001.DAT` from the install (short-circuits when absent), decodes the top-level container, and asserts the vanilla-1.07 chunk set (`NAME`, `INFO`, `PLYR`, `UNIT`, `BLDG`, `MAP `) is present and the version word is `0x0290`.
- Failure paths: non-`FORM` magic, wrong inner tag, truncated length, and chunk bodies that exceed the file boundary each produce a distinct `DecodeError`.

## 6. Not covered here

Per-chunk bodies below `INFO` (unit records, structure records, script engine serialisation, the `SaveLoadDesc` offset tables for `PLYR` / `UNIT` / `BLDG` / `MAP ` / `TEAM`) are deliberately left to follow-up work. That porting happens chunk-by-chunk as each pool / system gains the fields it needs to round-trip.

## 7. `INFO` chunk body

Once the container has handed us the `INFO` blob, the first two bytes are the little-endian savegame version (covered in §3). Everything after that is a flat dump of OpenDUNE's `s_saveInfo` table from `src/saveload/info.c`, which in turn nests the `g_saveScenario` table from `src/saveload/scenario.c`. Every integer is stored little-endian — the chunk's `u32 BE` length in the container header is the only big-endian value in the file.

### 7.1 Nested `Scenario` block (228 bytes)

The very first bytes of the post-version payload are the `g_saveScenario` dump — the scenario mirror of `g_scenario` at save-time.

| Offset | Size | Type       | Field                                          |
|-------:|-----:|------------|------------------------------------------------|
|      0 |    2 | `u16 LE`   | `score` — cumulative score meter.              |
|      2 |    2 | `u16 LE`   | `winFlags` — bitfield of win conditions.       |
|      4 |    2 | `u16 LE`   | `loseFlags` — bitfield of lose conditions.     |
|      6 |    4 | `u32 LE`   | `mapSeed` — seed for `Map_CreateLandscape`.    |
|     10 |    2 | `u16 LE`   | `mapScale` — briefing map zoom level.          |
|     12 |    2 | `u16 LE`   | `timeOut` — scenario time limit (ticks).       |
|     14 |   14 | `u8[14]`   | `pictureBriefing` — WSA filename, NUL-padded.  |
|     28 |   14 | `u8[14]`   | `pictureWin` — win-screen WSA filename.        |
|     42 |   14 | `u8[14]`   | `pictureLose` — lose-screen WSA filename.      |
|     56 |    2 | `u16 LE`   | `killedAllied` — allied losses counter.        |
|     58 |    2 | `u16 LE`   | `killedEnemy` — enemy losses counter.          |
|     60 |    2 | `u16 LE`   | `destroyedAllied` — allied structures lost.    |
|     62 |    2 | `u16 LE`   | `destroyedEnemy` — enemy structures lost.      |
|     64 |    2 | `u16 LE`   | `harvestedAllied` — allied credits harvested.  |
|     66 |    2 | `u16 LE`   | `harvestedEnemy` — enemy credits harvested.    |
|     68 |  160 | `record[16]` | `reinforcement[16]` — 10-byte records (below). |

Each `Reinforcement` record is 5 × `u16 LE`:

| Offset | Size | Type     | Field                                                      |
|-------:|-----:|----------|------------------------------------------------------------|
|      0 |    2 | `u16 LE` | `unitID` — unit-type index (`0xFFFF` = empty slot).        |
|      2 |    2 | `u16 LE` | `locationID` — spawn location table index.                 |
|      4 |    2 | `u16 LE` | `timeLeft` — ticks until delivery.                         |
|      6 |    2 | `u16 LE` | `timeBetween` — re-arm interval (if `repeat`).             |
|      8 |    2 | `u16 LE` | `repeat` — non-zero → recurring reinforcement.             |

Total nested block: 68 + 160 = 228 bytes.

### 7.2 Top-level info fields (100 bytes)

Immediately following the nested scenario block:

| Offset | Size | Type       | Field                                                                   |
|-------:|-----:|------------|-------------------------------------------------------------------------|
|    228 |    2 | `u16 LE`   | `playerCreditsNoSilo` — on-the-wire player credits.                     |
|    230 |    2 | `u16 LE`   | `minimapPosition` — packed tile index (copied into `viewportPosition`). |
|    232 |    2 | `u16 LE`   | `selectionRectanglePosition` — packed tile of selection rect.           |
|    234 |    1 | `i8`       | `selectionType` — selection mode (callback `SaveLoad_SelectionType`).   |
|    235 |    1 | `i8`       | `structureActiveType` — i8 on disk, widened to u16 in memory.           |
|    236 |    2 | `u16 LE`   | `structureActivePosition` — packed tile being placed.                   |
|    238 |    2 | `u16 LE`   | `structureActiveIndex` — structure slot (`0xFFFF` when none).           |
|    240 |    2 | `u16 LE`   | `unitSelectedIndex` — unit slot (`0xFFFF` when none).                   |
|    242 |    2 | `u16 LE`   | `unitActiveIndex` — unit slot (`0xFFFF` when none).                     |
|    244 |    2 | `u16 LE`   | `activeAction` — current active-action enum.                            |
|    246 |    4 | `u32 LE`   | `strategicRegionBits` — region mask on the strategic map.               |
|    250 |    2 | `u16 LE`   | `scenarioID` — mission number (1 … 22).                                 |
|    252 |    2 | `u16 LE`   | `campaignID` — house campaign number (1 … 9).                           |
|    254 |    4 | `u32 LE`   | `hintsShown1` — in-game hints bitfield.                                 |
|    258 |    4 | `u32 LE`   | `hintsShown2` — in-game hints bitfield.                                 |
|    262 |    4 | `u32 LE`   | `scenarioElapsedTicks` — delta from `g_timerGame` at save time.         |
|    266 |    2 | `u16 LE`   | *duplicate* `playerCreditsNoSilo` (see §7.3).                           |
|    268 |   54 | `i16[27]`  | `starportAvailable[27]` — per-unit-type stock, `-1` = unknown.          |
|    322 |    2 | `u16 LE`   | `houseMissileCountdown` — ticks until the house missile is ready.       |
|    324 |    2 | `u16 LE`   | `unitHouseMissileIndex` — owning unit (`0xFFFF` when none).             |
|    326 |    2 | `u16 LE`   | `structureIndex` — last-touched structure slot.                         |

Total top-level fields: 100 bytes. Grand total for the body *after* the version word: 228 + 100 = 328 bytes. The chunk's full byte length is therefore exactly 330 (version word + payload), and OpenDUNE's `Info_Load` rejects the chunk unless `SaveLoad_GetLength(s_saveInfo) == length - 2`.

### 7.3 Duplicate `playerCreditsNoSilo`

Field offset 228 and offset 266 both store `g_playerCreditsNoSilo` (same global). The second write overwrites the first on load — the serialised table simply references the same pointer twice. Our decoder reads both values; when they disagree (which they never will in saves produced by a live game), the *second* wins, matching OpenDUNE. The duplicate costs 2 bytes and is not a distinct field — we expose a single `playerCreditsNoSilo` in the Swift model.

### 7.4 Callbacks, version gate, legacy saves

Several fields go through callbacks on load: `selectionType`, `structureActive*`, `unitSelected`, `unitActive`, `unitHouseMissile`, and `scenarioElapsedTicks`. On disk they are plain integers; the callbacks only matter when reconstructing live pointers back in OpenDUNE's runtime. Our port treats these purely as raw integers at the chunk level — resolving them to real pool slots happens in a higher layer.

If the leading version word is anything other than `0x0290`, OpenDUNE routes through `s_saveInfoOld`: 250 pad bytes, then `u16 scenarioID`, then `u16 campaignID`. This is the "original Westwood-era save" path and is only used to restart the battle. We surface a separate `Formats.Save.Info.decodeLegacy(_:)` entry point for it; the modern layout above is the default.

## 8. `PLYR` chunk body

The `PLYR` chunk holds every allocated House as a packed sequence of fixed-width records — no header, no count. OpenDUNE's `House_Load` simply reads records while the chunk has bytes left and rejects the chunk unless `length` is an exact multiple of the per-slot size.

Record source: `s_saveHouse` in `src/saveload/house.c`. Every field is little-endian.

### 8.1 Per-slot layout (66 bytes)

| Offset | Size | Type       | Field                                                              |
|-------:|-----:|------------|--------------------------------------------------------------------|
|      0 |    2 | `u16 LE`   | `index` — house ID (0 = Harkonnen … 5 = Mercenary).                |
|      2 |    2 | `u16 LE`   | `harvestersIncoming` — pending harvester deliveries.               |
|      4 |    2 | `u16 LE`   | `flags` — `HouseFlags` bits, see §8.2.                             |
|      6 |    2 | `u16 LE`   | `unitCount` — units owned by this house.                           |
|      8 |    2 | `u16 LE`   | `unitCountMax` — cap on owned units.                               |
|     10 |    2 | `u16 LE`   | `unitCountEnemy` — units owned by enemies.                         |
|     12 |    2 | `u16 LE`   | `unitCountAllied` — units owned by allies.                         |
|     14 |    4 | `u32 LE`   | `structuresBuilt` — bitmask of structure-types ever built.         |
|     18 |    2 | `u16 LE`   | `credits` — cash on hand.                                          |
|     20 |    2 | `u16 LE`   | `creditsStorage` — silo capacity.                                  |
|     22 |    2 | `u16 LE`   | `powerProduction` — watts produced.                                |
|     24 |    2 | `u16 LE`   | `powerUsage` — watts consumed.                                     |
|     26 |    2 | `u16 LE`   | `windtrapCount` — windtraps on map.                                |
|     28 |    2 | `u16 LE`   | `creditsQuota` — credits-to-win target.                            |
|     30 |    2 | `u16 LE`   | `palacePositionX` — palace tile X.                                 |
|     32 |    2 | `u16 LE`   | `palacePositionY` — palace tile Y.                                 |
|     34 |    2 | `u16 LE`   | *pad* — `SLD_EMPTY(UINT16)`, always zero.                          |
|     36 |    2 | `u16 LE`   | `timerUnitAttack` — cooldown for "unit approaching" alert.         |
|     38 |    2 | `u16 LE`   | `timerSandwormAttack` — cooldown for "sandworm approaching" alert. |
|     40 |    2 | `u16 LE`   | `timerStructureAttack` — cooldown for "base under attack" alert.   |
|     42 |    2 | `u16 LE`   | `starportTimeLeft` — ticks until starport delivery.                |
|     44 |    2 | `u16 LE`   | `starportLinkedID` — head of starport unit linked list.            |
|     46 |   20 | `u16[10]`  | `aiStructureRebuild` — AI "rebuild this" queue, five `(type, pos)` pairs. |

Total per slot: 66 bytes (21 × `u16` + 1 × `u32` + 10 × `u16` array). Chunk body size is `allocatedHouseCount × 66`.

### 8.2 `HouseFlags` bits at offset 4

The flags word is stored as a 16-bit integer but the bit layout is fixed (OpenDUNE `saveload/saveload.c:150–158`):

| Bit    | Flag                   | Meaning                                         |
|-------:|------------------------|-------------------------------------------------|
| `0x01` | `used`                 | Slot is live.                                   |
| `0x02` | `human`                | This house is the local player.                 |
| `0x04` | `doneFullScaleAttack`  | AI has already committed its big-attack script. |
| `0x08` | `isAIActive`           | AI decision ticks are running for this house.   |
| `0x10` | `radarActivated`       | Radar has been unlocked.                        |

Bits `0x20…0x8000` are unused and written as zero.

### 8.3 Allocation rules, not the chunk's business

`House_Load` calls `House_Allocate(hl.index)` after reading each record — it relies on the save's `index` field rather than inferring from position. Our decoder surfaces `index` verbatim and leaves allocation / slot-mapping to a higher layer. Records are returned in file order, not index order, and vanilla 1.07 saves do not guarantee a stable ordering: the writer walks `House_Find`, which yields allocated slots by `findArray` insertion order.

## 9. `UNIT` chunk body

The `UNIT` chunk holds every allocated Unit as a packed sequence of 128-byte records. Each record layers three blocks from the OpenDUNE save tables: an `Object` header (`g_saveObject` in `src/saveload/object.c`), which itself nests a `ScriptEngine` state block (`g_saveScriptEngine` in `src/saveload/scriptengine.c`), followed by a unit-specific tail (`s_saveUnit` in `src/saveload/unit.c`).

The `ODUN` chunk is a separate "new Unit information" stream whose format is OpenDUNE-only. Vanilla 1.07 saves don't emit it (see `format-save-odun-is-opendune-only.md`); we still decode it for completeness on synthetic fixtures.

### 9.1 `ScriptEngine` block (55 bytes)

Nested inside every `Object`. Every integer is little-endian.

| Offset | Size | Type     | Field                                                       |
|-------:|-----:|----------|-------------------------------------------------------------|
|      0 |    2 | `u16 LE` | `delay` — ticks until the VM runs again.                    |
|      2 |    4 | `u32 LE` | `scriptOffset` — word offset of next instruction; callback. |
|      6 |    4 | `u32 LE` | *pad* — `SLD_EMPTY(UINT32)`.                                |
|     10 |    2 | `u16 LE` | `returnValue` — last `SETRETURNVALUE` result.               |
|     12 |    1 | `u8`     | `framePointer` — frame-base index.                          |
|     13 |    1 | `u8`     | `stackPointer` — stack top (grows down from 15).            |
|     14 |   10 | `u16[5]` | `variables` — EMC variable slots.                           |
|     24 |   30 | `u16[15]` | `stack` — operand / return stack.                          |
|     54 |    1 | `u8`     | `isSubroutine` — non-zero iff the VM is inside a `JUMP`.    |

The `scriptOffset` callback converts pointer ↔ offset on save/load; on disk it is simply the number of `u16` words into the entry-point's code at which the VM will resume.

### 9.2 `Object` header (71 bytes)

| Offset | Size | Type       | Field                                                            |
|-------:|-----:|------------|------------------------------------------------------------------|
|      0 |    2 | `u16 LE`   | `index` — pool slot index of this object.                        |
|      2 |    1 | `u8`       | `type` — unit/structure type ID.                                 |
|      3 |    1 | `u8`       | `linkedID` — index of a chained object (`0xFF` when none).       |
|      4 |    4 | `u32 LE`   | `flags` — `ObjectFlags` bitfield, see §9.3. Disk type is `u32`.  |
|      8 |    1 | `u8`       | `houseID` — owning house (0 = Harkonnen … 5 = Mercenary).        |
|      9 |    1 | `u8`       | `seenByHouses` — 6-bit mask of houses that have spotted this.    |
|     10 |    2 | `u16 LE`   | `positionX` — 16-bit sub-tile X (tile = top 6 bits of byte).     |
|     12 |    2 | `u16 LE`   | `positionY` — 16-bit sub-tile Y.                                 |
|     14 |    2 | `u16 LE`   | `hitpoints` — current HP.                                        |
|     16 |   55 | `struct`   | `script` — nested `ScriptEngine` block (§9.1).                   |

### 9.3 `ObjectFlags` bits

Disk word is `u32 LE`; only 18 bits are meaningful. Layout taken verbatim from OpenDUNE `saveload/saveload.c:160–182`:

| Bit        | Flag              | Meaning                                                 |
|-----------:|-------------------|---------------------------------------------------------|
| `0x000001` | `used`            | Slot is allocated.                                      |
| `0x000002` | `allocated`       | Has been fully constructed (vs. reserved).              |
| `0x000004` | `isNotOnMap`      | Object is invisible / in-transport / stored.            |
| `0x000008` | `isSmoking`       | Smoke animation is active.                              |
| `0x000010` | `fireTwiceFlip`   | Weapon alternates barrels each shot.                    |
| `0x000020` | `animationFlip`   | Frame flip toggle.                                      |
| `0x000040` | `bulletIsBig`     | Fires large projectile.                                 |
| `0x000080` | `isWobbling`      | Movement wobble animation active.                       |
| `0x000100` | `inTransport`     | Currently loaded into a carryall / transport.           |
| `0x000200` | `byScenario`      | Placed via the scenario INI, not spawned.               |
| `0x000400` | `degrades`        | HP slowly decays over time.                             |
| `0x000800` | `isHighlighted`   | UI selection highlight.                                 |
| `0x001000` | `isDirty`         | Needs redraw.                                           |
| `0x002000` | `repairing`       | Structure is repairing itself.                          |
| `0x004000` | `onHold`          | Production is on hold.                                  |
| `0x010000` | `isUnit`          | Object is a Unit (as opposed to a Structure).           |
| `0x020000` | `upgrading`       | Structure is upgrading.                                 |

Bits `0x8000`, `0x080000…0xFF000000`, and the explicitly-cleared `notused_*` slots are written as zero.

### 9.4 Unit tail (57 bytes)

Follows the `Object` header; starts at offset 71 in the record.

| Offset | Size | Type       | Field                                                                  |
|-------:|-----:|------------|------------------------------------------------------------------------|
|     71 |    2 | `u16 LE`   | *pad* — `SLD_EMPTY(UINT16)`.                                           |
|     73 |    2 | `u16 LE`   | `currentDestinationX`.                                                 |
|     75 |    2 | `u16 LE`   | `currentDestinationY`.                                                 |
|     77 |    2 | `u16 LE`   | `originEncoded` — packed spawn point.                                  |
|     79 |    1 | `u8`       | `actionID` — current `UNIT_ACTION_*` enum.                             |
|     80 |    1 | `u8`       | `nextActionID` — queued next action.                                   |
|     81 |    1 | `u8`       | `fireDelay` — **narrowed to `u8` on disk** from `u16` in memory.       |
|     82 |    2 | `u16 LE`   | `distanceToDestination` — pathing cost.                                |
|     84 |    2 | `u16 LE`   | `targetAttack` — encoded target (unit/tile/structure).                 |
|     86 |    2 | `u16 LE`   | `targetMove` — encoded move target.                                    |
|     88 |    1 | `u8`       | `amount` — cargo for harvesters etc.                                   |
|     89 |    1 | `u8`       | `deviated` — Ordos deviator countdown, non-zero iff deviated.          |
|     90 |    2 | `u16 LE`   | `targetLastX`.                                                         |
|     92 |    2 | `u16 LE`   | `targetLastY`.                                                         |
|     94 |    2 | `u16 LE`   | `targetPreLastX`.                                                      |
|     96 |    2 | `u16 LE`   | `targetPreLastY`.                                                      |
|     98 |    6 | `struct[2]`| `orientation[2]` — two 3×`i8` `dir24` records: `(speed, target, current)`. |
|    104 |    1 | `u8`       | `speedPerTick`.                                                        |
|    105 |    1 | `u8`       | `speedRemainder`.                                                      |
|    106 |    1 | `u8`       | `speed`.                                                               |
|    107 |    1 | `u8`       | `movingSpeed`.                                                         |
|    108 |    1 | `u8`       | `wobbleIndex`.                                                         |
|    109 |    1 | `i8`       | `spriteOffset` — signed.                                               |
|    110 |    1 | `u8`       | `blinkCounter`.                                                        |
|    111 |    1 | `u8`       | `team` — AI team assignment (1-based, 0 = no team).                    |
|    112 |    2 | `u16 LE`   | `timer`.                                                               |
|    114 |   14 | `u8[14]`   | `route` — pathfinding waypoint queue.                                  |

Record total: 71 (Object) + 57 (tail) = **128 bytes per unit**. Chunk body is a multiple of 128.

### 9.5 `ODUN` chunk body (synthetic only in vanilla)

`ODUN` rides in addition to `UNIT` whenever OpenDUNE writes the save. Each entry is `{ u16 index, u16 fireDelay, u8 deviatedHouse, u8 pad, u16[6] pad }` — 18 bytes — and patches the full-width `fireDelay` (the `UNIT` chunk narrowed it to `u8`) plus records which house deviated a unit (pre-ODUN Dune II assumed Ordos). The `deviated` flag on the `UNIT` record already tells us the unit *is* deviated; `deviatedHouse` disambiguates which house did it.

Vanilla 1.07 saves never emit `ODUN`. Our decoder reads it when present and skips it silently when absent; the two chunks can round-trip independently but the application layer is responsible for merging them by `index`.

## 10. `BLDG` chunk body

The `BLDG` chunk holds every allocated Structure as a packed sequence of 88-byte records. Like `UNIT`, each record starts with the 71-byte `ObjectHeader` (§9.2 — same layout, same `ObjectFlags` bitfield, same nested `ScriptState`), followed by a 17-byte structure-specific tail (`s_saveStructure` in `src/saveload/structure.c`).

### 10.1 Structure tail (17 bytes, starts at offset 71)

| Offset | Size | Type       | Field                                                                  |
|-------:|-----:|------------|------------------------------------------------------------------------|
|     71 |    2 | `u16 LE`   | `creatorHouseID` — house that placed this structure.                   |
|     73 |    2 | `u16 LE`   | `rotationSpriteDiff` — turret/rotation offset into the sprite sheet.   |
|     75 |    1 | `u8`       | *pad* — `SLD_EMPTY(UINT8)`.                                            |
|     76 |    2 | `u16 LE`   | `objectType` — what this structure is currently producing.             |
|     78 |    1 | `u8`       | `upgradeLevel` — 0 = base, 1 = first upgrade, …                        |
|     79 |    1 | `u8`       | `upgradeTimeLeft` — percent remaining on the current upgrade.          |
|     80 |    2 | `u16 LE`   | `countDown` — generic countdown (build ticks, repair, etc.).           |
|     82 |    2 | `u16 LE`   | `buildCostRemainder` — fractional credits-per-tick accumulator.        |
|     84 |    2 | `i16 LE`   | `state` — `StructureState` enum; **signed** so `-1` = invalid.         |
|     86 |    2 | `u16 LE`   | `hitpointsMax` — ceiling for HP, possibly upgraded.                    |

Record total: 71 + 17 = **88 bytes per structure**. Chunk body is a multiple of 88.

### 10.2 Reserved structure slots are not in the chunk

The runtime structure pool reserves indices 79, 80, 81 for the three aggregate "slabs / walls" collections (see `Documentation/Architecture/Pools.md` §5). Those reserved slots never go through `Structure_Save` — the save writer walks `Structure_Find`, which visits only slots in the `findArray` (the allocated `[0, 78]` range). A vanilla save therefore contains 0…79 real structure records, never 80 or more.

### 10.3 `isUnit` is always clear on disk

Because every `BLDG` record is a Structure, its `ObjectFlags.isUnit` bit (bit `0x010000`) is always zero on disk. Conversely, every `UNIT` record has that bit set. A decoder that treats the two chunks uniformly can use the flag as a disambiguator — but the chunk tag is still authoritative.

## 11. `MAP ` chunk body

The `MAP ` chunk (trailing space, see §1) holds the 64 × 64 tile grid — but **sparsely**. OpenDUNE's writer walks all 4096 cells and emits a record only for tiles that differ from the map-seed-generated baseline or carry dynamic state (unveiled, structure, unit, animation, explosion). Reference: `src/saveload/map.c`.

### 11.1 Record layout (6 bytes)

Each record is a `u16 LE` cell index followed by a 4-byte packed `Tile`:

| Offset | Size | Type       | Field                                                                 |
|-------:|-----:|------------|-----------------------------------------------------------------------|
|      0 |    2 | `u16 LE`   | `cellIndex` — position in the 64×64 grid: `y × 64 + x`, range 0…4095. |
|      2 |    4 | `u8[4]`    | Packed `Tile` — see §11.2.                                            |

Records are emitted in ascending `cellIndex` order. The loader does not validate ordering, so decoders should tolerate any order but can assert ascending on real-data fixtures.

### 11.2 Packed `Tile` bit layout

The 4 bytes pack eight named fields:

| Source | Bits in byte               | Field          | Range       | Notes                                           |
|--------|----------------------------|----------------|-------------|-------------------------------------------------|
| `b[0]` | all 8 bits                 | `groundTileID` low byte | —  | Combined with `b[1]` bit 0 for the 9-bit value. |
| `b[1]` | bit 0                      | `groundTileID` bit 8 | —    |                                                 |
| `b[1]` | bits 1..7                  | `overlayTileID` | 0…127       | 7-bit overlay sprite ID.                        |
| `b[2]` | bits 0..2                  | `houseID`      | 0…7         | Owning house for this tile.                     |
| `b[2]` | bit 3                      | `isUnveiled`   | bool        | Fog-of-war lifted.                              |
| `b[2]` | bit 4                      | `hasUnit`      | bool        |                                                 |
| `b[2]` | bit 5                      | `hasStructure` | bool        |                                                 |
| `b[2]` | bit 6                      | `hasAnimation` | bool        |                                                 |
| `b[2]` | bit 7                      | `hasExplosion` | bool        |                                                 |
| `b[3]` | all 8 bits                 | `tileIndex`    | 0…255       | Structure/Unit pool index + 1; `0` = none.      |

`tileIndex` is **off-by-one** with respect to the pool index it refers to — value `1` means "Structure/Unit index 0", value `0` means "no object on this tile". Honour that when cross-referencing `UNIT` / `BLDG` slots.

The 9-bit `groundTileID` spans bytes 0 and 1:

```
groundTileID = b[0] | ((b[1] & 0x01) << 8)
overlayTileID = b[1] >> 1
```

### 11.3 Sparse baseline — what "missing" means

A tile absent from the `MAP ` chunk means "keep the map-seed-generated ground, no overlay override, no unveil, no unit / structure / animation / explosion on this tile". `Map_Load` reconstructs the baseline by:

1. Zeroing all 4096 tiles, then
2. Setting `isUnveiled = false` and `overlayTileID = g_veiledTileID` (the veiled-fog sprite ID, set up by `Sprites_LoadTiles()`), then
3. Applying each sparse record in turn.

Our decoder surfaces the sparse list only. Producing a fully-stamped 4096-tile grid requires a baseline — typically `Core.Map.Generator` driven by the scenario's `mapSeed`, plus the veiled-tile ID resolved via the icon map. That reconstruction belongs to a higher layer.

### 11.4 Record count bounds

Record count ranges from 0 (impossible in practice) to 4096 inclusive. Chunk body length is `recordCount × 6`. A single real save typically holds a few hundred records at the start of a mission (scouted region plus structures/units overlaid) and grows toward the cap as the map is uncovered.

Anything outside the 4096-cell grid — `cellIndex ≥ 0x1000` — is a corrupted save; OpenDUNE rejects it with `return false`. We surface that as a dedicated `DecodeError`.

## 12. Assembling a full save — `Formats.Save.Game`

The per-chunk decoders (`Container`, `Info`, `Player`, `Units`, `Structures`, `TileMap`) are independently useful, but callers most often want "load a `_SAVE00?.DAT` file and hand me back everything". `Formats.Save.Game` is that composition — a pure function over the file bytes that walks the container, finds each required chunk, and routes its body through the appropriate body decoder.

### 12.1 Contract

`Formats.Save.Game.decode(_ data: Data) throws -> Game` succeeds when:

1. The container walks cleanly (same rules as §4) and the savegame version at the head of `INFO` is `0x0290`.
2. Every chunk in the **required set** decodes cleanly:
   - `NAME` — savegame description, ASCII up to 255 bytes, NUL-terminated. Surfaced as Swift `String`.
   - `INFO` — decoded via `Save.Info`.
   - `PLYR` — decoded via `Save.Player`.
   - `UNIT` — decoded via `Save.Units`.
   - `BLDG` — decoded via `Save.Structures`.
   - `MAP ` — decoded via `Save.TileMap`.
3. Optional chunks (`TEAM`, `ODUN`) are decoded when present and left `nil` when absent. Vanilla 1.07 never emits them — see `format-save-odun-is-opendune-only.md`.

Unknown chunks (any 4CC outside the required-or-optional set) are ignored. This matches OpenDUNE's `Load_Main` behaviour: it prints a warning and skips by length.

### 12.2 Failure modes

Every failure maps to a distinct error case on `Save.Game.DecodeError`:

| Case                                      | Triggered by                                                        |
|-------------------------------------------|---------------------------------------------------------------------|
| `.container(Save.Container.DecodeError)`  | Non-FORM magic, wrong inner `SCEN`, chunk length past EOF, etc.      |
| `.missingRequiredChunk(tag:)`             | One of the six required chunks absent from the container index.      |
| `.info(Save.Info.DecodeError)`            | `INFO` body fails — legacy version, truncation, etc.                 |
| `.player(Save.Player.DecodeError)`        | `PLYR` body is not a multiple of 66 bytes.                           |
| `.units(Save.Units.DecodeError)`          | `UNIT` body is not a multiple of 128 bytes.                          |
| `.structures(Save.Structures.DecodeError)`| `BLDG` body is not a multiple of 88 bytes.                           |
| `.tileMap(Save.TileMap.DecodeError)`      | `MAP ` body misaligned or a `cellIndex ≥ 0x1000` is present.         |
| `.nameNotAscii`                           | `NAME` body has a byte ≥ 0x80 before the first NUL.                  |

These errors wrap the underlying chunk errors verbatim — the application layer can pattern-match to pinpoint the exact byte-level failure.

### 12.3 What `Game` does *not* do

- No pool allocation. The `Save.Player.HouseSlot` / `Save.Units.Slot` / `Save.Structures.Slot` values are raw record data; translating them into a live `Simulation.*Pool` is a separate concern.
- No map reconstruction. `TileMap` is sparse (§11); the full 64×64 grid needs `Core.Map.Generator(mapSeed: info.scenario.mapSeed)` as the baseline with `tileMap.entries` layered on top.
- No script resumption. Each object carries a `ScriptState` block, but hooking it up to a live `Scripting.VM` requires pointing `scriptOffset` at the matching EMC program — outside the save decoder's scope.
