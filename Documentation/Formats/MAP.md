# ICON.MAP — terrain tile group index

Status: Documented 2026-04-19

`ICON.MAP` pairs with `ICON.ICN`. On its own, ICN is a flat list of 16×16 tiles indexed 0…N. `ICON.MAP` layers *semantic groups* on top — "these tile IDs are fog-of-war overlays", "these are the spice-bloom frames", "these are the walls" — so gameplay code can ask for `IconGroup.walls[2]` instead of hard-coding a tile number.

References:

- OpenDUNE `src/sprites.h` · the `ICM_ICONGROUP_*` enum.
- OpenDUNE `src/sprites.c` · `Sprites_LoadTiles` consumes it.
- Our decoder: `Formats.IconMap` in `Code/Core/Sources/DuneIICore/Formats/IconMap/`.

## 1. Layout

The file is a flat array of little-endian `UInt16`. The first 28 entries form the *group header*: each `map[i]` is an index **back into the same array** where group `i`'s tile IDs begin.

```
offset  content (u16 LE)
0       start index of group  0 (ROCK_CRATERS)
2       start index of group  1 (SAND_CRATERS)
...
26*2    start index of group 26 (RADAR_OUTPOST)
27*2    end sentinel — index one past the last tile ID
28*2…   concatenated tile-ID runs, one run per group
```

Group `g` occupies `map[map[g] ..< map[g + 1]]`. To fetch tile ID `k` within group `g`:

```
tileId = map[ map[g] + k ]
```

This doubled indirection is exactly how OpenDUNE indexes:

```c
g_veiledTileID = g_iconMap[g_iconMap[ICM_ICONGROUP_FOG_OF_WAR] + 16];
```

## 2. Groups (per OpenDUNE `sprites.h`)

| ID | Name                      | Example use                       |
|----|---------------------------|-----------------------------------|
| 0  | —                         | Padding / unused                  |
| 1  | ROCK_CRATERS              | Craters from explosions on rock   |
| 2  | SAND_CRATERS              | Craters from explosions on sand   |
| 3  | FLY_MACHINES_CRASH        | Carryall / ornithopter crash frames |
| 4  | SAND_DEAD_BODIES          | Body overlays on sand             |
| 5  | SAND_TRACKS               | Vehicle tracks                    |
| 6  | WALLS                     | Wall tile variants                |
| 7  | FOG_OF_WAR                | Fog overlays                      |
| 8  | CONCRETE_SLAB             | Pre-built slab                    |
| 9  | LANDSCAPE                 | Base landscape tiles              |
| 10 | SPICE_BLOOM               | Animation frames for spice bloom  |
| 11 | HOUSE_PALACE              | Palace structure tiles            |
| 12 | LIGHT_VEHICLE_FACTORY     | Factory tiles                     |
| 13 | HEAVY_VEHICLE_FACTORY     | "                                 |
| 14 | HI_TECH_FACTORY           | "                                 |
| 15 | IX_RESEARCH               | "                                 |
| 16 | WOR_TROOPER_FACILITY      | "                                 |
| 17 | CONSTRUCTION_YARD         | "                                 |
| 18 | INFANTRY_BARRACKS         | "                                 |
| 19 | WINDTRAP_POWER            | "                                 |
| 20 | STARPORT_FACILITY         | "                                 |
| 21 | SPICE_REFINERY            | "                                 |
| 22 | VEHICLE_REPAIR_CENTRE     | "                                 |
| 23 | BASE_DEFENSE_TURRET       | "                                 |
| 24 | BASE_ROCKET_TURRET        | "                                 |
| 25 | SPICE_STORAGE_SILO        | "                                 |
| 26 | RADAR_OUTPOST             | "                                 |
| 27 | EOF                       | Sentinel — index one past the last tile |

`Formats.IconMap.Group` ships as a Swift `enum Int` with the same numeric values.

## 3. Swift API

```swift
let data = pak.body(named: "ICON.MAP")!
let map = try Formats.IconMap.decode(data)
let wallTiles = map.tileIds(in: .walls)          // [UInt16]
let spiceBloom0 = map.tileId(in: .spiceBloom, offset: 0)
let veiled = map.tileId(in: .fogOfWar, offset: 16)
```

## 4. Testing

`Core/Tests/DuneIICoreTests/IconMapTests.swift`:

1. Synthetic three-group file: manually built byte buffer where group indices are known, assert `tileIds(in:)` returns the right slice.
2. `tileId(in:offset:)` matches OpenDUNE's indexing on the same buffer.
3. If `DUNE.PAK` is present, real `ICON.MAP` decodes and its `map.groupCount == 28`. A spot check on `fogOfWar + 16` yields a non-zero tile ID.

## 5. Related insights

- [format-icn-subpalette-indirection](../Insights/format-icn-subpalette-indirection.md) — the ICN companion format these tile IDs resolve into.
