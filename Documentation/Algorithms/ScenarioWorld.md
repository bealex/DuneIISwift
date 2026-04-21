# ScenarioWorld — typed world snapshot

Status: Drafted 2026-04-20 (P3 kickoff)

`ScenarioWorld` combines `Core.Scenario` (static INI-derived config) and `Core.Map.Map` (dynamic 64×64 tile grid). It's the handoff between the "data" layer (format decoders + typed scenario) and the "runtime" layer (simulation actor + renderer).

References:

- OpenDUNE `src/scenario.c::Scenario_Load` drives the equivalent of this in the C codebase.
- Our implementation: `Core.ScenarioWorld` in `Code/Core/Sources/DuneIICore/Scenario/ScenarioWorld.swift`.

## 1. Responsibilities

A `ScenarioWorld`:

1. Holds the parsed `Scenario` and a concrete `Map` grid.
2. Stamps each `StructureSpawn` onto the grid, marking its cell as `hasStructure = true`. For `GEN`-keyed slabs, it writes `groundTileID = builtSlabTileID`.
3. Stamps each `UnitSpawn` as a **unit roster** entry (no tile-level side effects — units occupy positions, not cells).
4. Exposes queries: `units(at:)`, `structure(at:)`, `isBlocked(at:)`.

## 2. What it does *not* do (yet)

- No simulation tick — that's P4 (`GameActor`).
- No rendering — that's P2 slice 2 (`Rendering.Scene.Game`).
- No fog-of-war reveal around starting units; that belongs to the simulation's first tick.

## 3. Swift API

```swift
let scenario = try Scenario(iniData: iniData)
let resolver = TileResolver(iconMap: iconMap)
var world = ScenarioWorld(scenario: scenario, resolver: resolver)

world.map[30, 25].hasStructure          // true after stamping ConstYard at 1630
world.units(at: PackedPosition(raw: 1246)).first?.unitType  // .soldier
world.structure(at: PackedPosition(raw: 1630))?.structureType == .constructionYard
```

## 4. Testing

`Core/Tests/DuneIICoreTests/ScenarioWorldTests.swift`:

1. A single `[STRUCTURES]` entry stamps `hasStructure = true` on the correct cell.
2. `GEN`-keyed slab rows set `groundTileID = builtSlabTileID` at the position encoded in the key.
3. Two units at the same packed position come back in `units(at:)`.
4. A `MapField` spice seed is preserved in the stamped world.
5. Real `SCENA001.INI` + synthetic IconMap: Atreides construction yard ends up at packed position 1630.
