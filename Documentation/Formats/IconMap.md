# ICON.MAP (icon group index)

Groups `ICON.ICN` tiles into named icon groups (terrain/effects + structures). Reference: OpenDUNE `src/sprites.h:8` (layout doc + the `ICM_ICONGROUP_*` enum) and `Sprites_LoadTiles` (`src/sprites.c:263`). Port: `Code/Frameworks/DuneIIFormats/Formats/IconMap/IconMap.swift`. Tests: `Code/Tests/FormatsTests/IconMapTests.swift`.

## Layout

A flat array of little-endian `uint16` indices:
- Entry `0` = the icon-group count.
- Entries `1 ..< count` each hold an **offset** (into the same array) to that group's first tile ID.
- The entry at the count index is `0` (EOF).

Group `i`'s tile IDs are `values[ values[i] ..< values[i+1] ]` — from its offset up to (but not including) the next group's offset, or to end-of-array when the next offset is `0`. Each tile ID indexes a tile in `ICON.ICN`.

## Groups

Indices 1–10 are terrain/effects (rock/sand craters, machine crash, dead bodies, sand tracks, walls, fog of war, concrete slab, landscape, spice bloom). Indices 11–26 are structures: Palace, Light/Heavy/Hi-Tech factories, IX Research, WOR, Construction Yard, Barracks, Windtrap, Starport, Spice Refinery, Repair Centre, Gun Turret, Rocket Turret, Spice Silo, Radar Outpost. The render-test app surfaces these as its "Buildings" and "Terrain" categories.
