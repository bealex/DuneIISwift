# ICON.MAP uses double indirection: `map[map[group] + k]`

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/IconMap/IconMap.swift`
- **Category**: format
- **Applies to**: `Formats.IconMap`, future terrain/overlay rendering, explosion / animation systems (P4+).

## The fact

`ICON.MAP` is a flat `UInt16` array split into two logical regions living in the same buffer:

1. A **group header** of 28 entries (`map[0..27]`). Each entry is an **index** back into the same array where a group's tile IDs begin.
2. Concatenated runs of tile IDs that the header points at.

Group `g` spans `map[map[g] ..< map[g + 1]]`. The `k`-th tile ID is therefore `map[map[g] + k]` — OpenDUNE's exact idiom.

The "EOF" slot (`map[27]`) is a sentinel so `map[g + 1]` is valid for `g = 26` (RADAR_OUTPOST).

## Why it matters

Reading the header as "offsets into a second array" produces off-by-one errors that look correct on simple groups (ROCK_CRATERS) and silently explode on the complex ones (BASE_DEFENSE_TURRET, SPICE_BLOOM) where the runs share sub-sequences.

## Where it lives in our code

- `Formats.IconMap.tileIds(in:)` — computes the slice.
- `Formats.IconMap.tileId(in:offset:)` — matches OpenDUNE's idiom.
- `Tests/DuneIICoreTests/IconMapTests.swift::openduneIndexing` exercises `map.tileId(in: .walls, offset: 2)` against a hand-built buffer.

## Where it lives in the reference

OpenDUNE `src/sprites.c`:

```c
g_veiledTileID    = g_iconMap[g_iconMap[ICM_ICONGROUP_FOG_OF_WAR] + 16];
g_bloomTileID     = g_iconMap[g_iconMap[ICM_ICONGROUP_SPICE_BLOOM]];
g_wallTileID      = g_iconMap[g_iconMap[ICM_ICONGROUP_WALLS]];
```

The enum values (`ICM_ICONGROUP_*`) live in `src/sprites.h`.
