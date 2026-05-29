# The runtime data model (`DuneIIWorld`)

The mutable game state is a faithful port of OpenDUNE's runtime structs. This doc is the design of record for the PODs, the object pools, and the `GameState` aggregate. Ground every field in its OpenDUNE source.

## Principles

- **PODs are value types (`struct`).** OpenDUNE keeps fixed-size pools of structs accessed by index/pointer; we keep Swift `struct`s in fixed-size arrays inside `GameState`. Copying `GameState` is a snapshot — which is exactly principle 4 (one owned aggregate, snapshottable). Code mutates objects in place via their pool index.
- **Faithful field-for-field**, including field order and width, because the eventual save-format port reads/writes these. Where C uses a pointer that the save serialises as an integer (the script program counter), we store that integer directly and note the deviation.
- **`Sendable` + `Equatable`.** No reference types inside the model; no globals (principle 8 of the engine, principle 4 here).
- **Bitfield unions → `OptionSet`.** OpenDUNE's flag unions (`ObjectFlags` with a `uint32 all`, `HouseFlags`, `TeamFlags`) become `OptionSet`s whose member `rawValue`s are the exact bit masks. `ObjectFlags`'s layout is golden-pinned against the oracle (it round-trips through `flags.all` in saves); the smaller house/team flag bytes are transcribed and will be re-verified by the save-format port.

## PODs

All under `DuneIIWorld/Model/`. Enums shared with render/input live in Contracts (`UnitType`, `StructureType`, `HouseID`); model-internal enums (`StructureState`, `TeamActionType`) live here.

- **`ObjectFlags`** (`src/object.h`, the union) — `OptionSet<UInt32>`: `used`(0), `allocated`(1), `isNotOnMap`(2), `isSmoking`(3), `fireTwiceFlip`(4), `animationFlip`(5), `bulletIsBig`(6), `isWobbling`(7), `inTransport`(8), `byScenario`(9), `degrades`(10), `isHighlighted`(11), `isDirty`(12), `repairing`(13), `onHold`(14), `isUnit`(16), `upgrading`(17). (Bits 15, 18–31 are unused in the original.)
- **`ScriptEngine`** (`src/script/script.h`) — `delay`, `scriptPC` (the C `uint16 *script` stored as its offset from `scriptInfo->start`, matching how the parity harness and the save format serialise it — the `scriptInfo` pointer is re-derived at runtime from the owner's type and is **not** stored), `returnValue`, `framePointer`, `stackPointer`, `variables[5]`, `stack[15]`, `isSubroutine`.
- **`Object`** (`src/object.h`) — the data common to a unit and a structure: `index`, `type`, `linkedID`, `flags` (`ObjectFlags`), `houseID`, `seenByHouses`, `position` (`Tile32`), `hitpoints`, `script` (`ScriptEngine`).
- **`Dir24`** (`src/unit.h`) — `speed`, `target`, `current` (all `Int8`); orientation triplet.
- **`Unit`** (`src/unit.h`) — embeds `Object`; adds `currentDestination`, `originEncoded`, `actionID`, `nextActionID`, `fireDelay`, `distanceToDestination`, `targetAttack`, `targetMove`, `amount`, `deviated`, `deviatedHouse`, `targetLast`, `targetPreLast`, `orientation[2]` (`Dir24`), `speedPerTick`, `speedRemainder`, `speed`, `movingSpeed`, `wobbleIndex`, `spriteOffset` (`Int8`), `blinkCounter`, `team`, `timer`, `route[14]`.
- **`StructureState`** (`src/structure.h`) — `detect`(-2), `justBuilt`(-1), `idle`(0), `busy`(1), `ready`(2). Signed.
- **`Structure`** (`src/structure.h`) — embeds `Object`; adds `creatorHouseID`, `rotationSpriteDiff`, `objectType`, `upgradeLevel`, `upgradeTimeLeft`, `countDown`, `buildCostRemainder`, `state` (`StructureState`), `hitpointsMax`.
- **`HouseFlags`** (`src/house.h`) — `OptionSet<UInt8>`: `used`(0), `human`(1), `doneFullScaleAttack`(2), `isAIActive`(3), `radarActivated`(4).
- **`House`** (`src/house.h`) — `index`, `harvestersIncoming`, `flags`, `unitCount`, `unitCountMax`, `unitCountEnemy`, `unitCountAllied`, `structuresBuilt`, `credits`, `creditsStorage`, `powerProduction`, `powerUsage`, `windtrapCount`, `creditsQuota`, `palacePosition` (`Tile32`), `timerUnitAttack`, `timerSandwormAttack`, `timerStructureAttack`, `starportTimeLeft`, `starportLinkedID`, `aiStructureRebuild[5][2]`.
- **`TeamActionType`** (`src/team.h`) — `normal`, `staging`, `flee`, `kamikaze`, `guard` (0–4).
- **`TeamFlags`** (`src/team.h`) — `OptionSet<UInt8>`: `used`(0).
- **`Team`** (`src/team.h`) — `index`, `flags`, `members`, `minMembers`, `maxMembers`, `movementType`, `action`, `actionStart`, `houseID`, `position` (`Tile32`), `targetTile`, `target`, `script` (`ScriptEngine`).
- **`MapTile`** (`src/map.h`'s `Tile`, 4 bytes) — `groundTileID`(9b), `overlayTileID`(7b), `houseID`(3b), `isUnveiled`(1b), `hasUnit`(1b), `hasStructure`(1b), `hasAnimation`(1b), `hasExplosion`(1b), `index`(8b). Modelled with stored properties + a packed `UInt32` round-trip (`init(packed:)` / `packed`) for save compatibility, golden-pinned like `ObjectFlags`.
- **`MapInfo`** (`src/map.h`) — `minX`, `minY`, `sizeX`, `sizeY` (the three map scales; `g_mapInfos`).

## Pools (next chunk, not yet built)

Fixed-size arrays sized to OpenDUNE's `*_INDEX_MAX` (units 102, structures 82, houses 6, teams 16) plus a dense "find array" of in-use indices, mirroring `Pool_FindFirst`/`Pool_FindNext` and the `Tools_Index_*` encoding. `Unit_Allocate` picks a free index inside the type's `[indexStart, indexEnd]` band (from `UnitInfo`). Building the pools unlocks the deferred `Tools_Index_Encode`/`IsValid`/`Get*` primitives.

## `GameState` (next chunk, not yet built)

The single owned aggregate: the unit/structure/house/team pools, the `MapTile[64*64]` grid (+ spice), both RNGs (`Random256`, `RandomLCG`), the two clocks (`g_timerGame`, `g_timerGUI`) and the speed/pause model, and the per-subsystem tick cursors. All build-availability flags hoisted out of the "static" stat tables (`ObjectInfo.available`) land here too.

## Testing

PODs are plain data; their real verification is the save-format round-trip (later). For now: the `ObjectFlags` (and `MapTile`) bit layouts are golden-pinned against the oracle (`Golden_ObjectFlags` in `src/parity.c` → `objectflags-golden.jsonl`), and Swift tests cover default construction, `Equatable`, and flag set/contains round-trips.
