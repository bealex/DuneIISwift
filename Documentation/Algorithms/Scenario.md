# Scenario — typed model over `SCEN?00?.INI`

Status: Drafted 2026-04-19 (P2 slice 1)

`Formats.Ini.Document` gives us raw sections and string values. The scenario loader wraps that with a typed representation that the simulation and rendering layers can consume without every caller reimplementing string → enum coercion.

References:

- OpenDUNE `src/scenario.c` · `Scenario_Load_*` functions parse each section of the INI.
- Our implementation: `Core.Scenario.Scenario` in `Code/Core/Sources/DuneIICore/Scenario/`.

## 1. INI → typed sections

| INI section  | Typed representation            | Meaning                                         |
|--------------|---------------------------------|-------------------------------------------------|
| `[BASIC]`    | `Scenario.Briefing`             | Win/lose pictures, briefing WSA, timeout, flags.|
| `[MAP]`      | `Scenario.MapField`             | Seed, starting spice field, initial bloom pos.  |
| `[House]`    | `Scenario.HouseLayout` (one per house: Atreides/Ordos/Harkonnen/etc.) | Starting credits, quota, brain, unit cap. |
| `[UNITS]`    | `[Scenario.UnitSpawn]`          | Pre-placed units.                                |
| `[STRUCTURES]` | `[Scenario.StructureSpawn]`   | Pre-placed structures (incl. walls / concrete). |
| `[REINFORCEMENTS]` | `[Scenario.Reinforcement]` | Scheduled arrivals (deferred to P3).             |
| `[TEAMS]`    | `[Scenario.TeamSpec]`           | AI team seed definitions (deferred).            |
| `[CHOAM]`    | `[Scenario.ChoamItem]`          | Starport supply table (deferred).                |

## 2. Entity row format

`[UNITS]` row:
```
IDnnn=House,UnitType,HitPoints,PackedPosition,Orientation,Action
```

- `House` — string matching one of Atreides/Ordos/Harkonnen/Fremen/Sardaukar/Mercenary.
- `UnitType` — string matching a unit table entry (Soldier, Trike, Carryall, …).
- `HitPoints` — integer in base-256 (256 == "100% of max HP").
- `PackedPosition` — u16 encoding `(y << 6) | x` where x/y are 6-bit
tile coordinates. `Tile.unpacked(from:)` decodes them.
- `Orientation` — `0…255` representing 0…360° (0 = north, clockwise).
- `Action` — initial AI state (Guard, Hunt, Ambush, …).

`[STRUCTURES]` row:
```
IDnnn=House,StructureType,HitPoints,PackedPosition
```

Special key prefix `GEN` (e.g. `GEN123=...`) denotes a slab or wall placed *at* the packed position encoded in the key digits. P3 handles this; P2 slice 1 keeps `GEN`-keyed rows as raw `StructureSpawn` entries with `isGenerated == true`.

## 3. Swift API sketch

```swift
let iniData = pak.body(named: "SCENA001.INI")!
let scenario = try Scenario(iniData: iniData)

scenario.briefing.winPicture              // "WIN1.WSA"
scenario.mapField.seed                    // 353
scenario.houses[.atreides]!.credits       // 1000
scenario.units.first?.position.packed     // 1246
scenario.units.first?.position.tile       // (x: 62, y: 19)
scenario.structures.map { $0.house }      // [.atreides]
```

## 4. Testing

`Core/Tests/DuneIICoreTests/ScenarioTests.swift`:

1. Parse a synthetic INI and assert `briefing`, `houses`, `units`, `structures` have the expected content.
2. `PackedPosition.tile` unpacks `1630` to `(x: 30, y: 25)` (1630 = 25 * 64 + 30).
3. Unknown `House` or `UnitType` values raise a typed error.
4. Real `SCENA001.INI`: loads, `houses[.atreides]!.credits == 1000`, 17 units, 1 structure.

## 5. What's deferred

`[REINFORCEMENTS]`, `[TEAMS]`, `[CHOAM]` — these feed simulation-layer systems (build schedules, AI, market) that don't exist yet. The parser produces typed rows for them in a future iteration; for now the `Scenario` struct exposes those sections as raw `Ini.Section` fall-throughs.

## 6. Related insights

- [format-ini-case-insensitive-keys](../Insights/format-ini-case-insensitive-keys.md) — the parser underneath honours this for free.
