# Map — 64×64 tile grid & landscape classification

Status: Drafted 2026-04-20 (P2 slice 1)

Every Dune II scenario plays on a fixed 64×64 tile grid. `Core.Map.Map` holds the mutable state — ground/overlay tile IDs per cell, spice amount, fog-of-war visibility — and offers typed queries over it. The tile IDs are indices into `Formats.Icn.TileSet`, resolved through `Formats.IconMap` groups.

References:

- OpenDUNE `src/map.c` · `Map_GetLandscapeType` and the `_landscapeSpriteMap` lookup table.
- OpenDUNE `src/map.h` · `LandscapeType` enum and `LandscapeInfo` fields.
- Our types: `Core.Map.*` in `Code/Core/Sources/DuneIICore/Map/`.

## 1. Types

```swift
public struct Map {
    public struct Cell {
        public var groundTileID: UInt16
        public var overlayTileID: UInt16
        public var spiceAmount: UInt8       // 0…? (engine-defined cap)
        public var hasStructure: Bool
        public var visibleToHouses: UInt8   // bitmask per House.rawValue
    }
    public static let width = 64
    public static let height = 64
    public var cells: [Cell]  // width * height, row-major (y * 64 + x)
}

public enum LandscapeType: Int, Sendable {
    case normalSand = 0, partialRock, entirelyDune, partialDune,
         entirelyRock, mostlyRock, entirelyMountain, partialMountain,
         spice, thickSpice, concreteSlab, wall, structure,
         destroyedWall, bloomField
}
```

## 2. TileResolver

`TileResolver` wraps `Formats.IconMap` with three derived tile IDs the engine pre-computes once:

```swift
public struct TileResolver {
    public let landscapeTileID: UInt16  // iconMap[iconMap[.landscape]]
    public let bloomTileID: UInt16      // iconMap[iconMap[.spiceBloom]]
    public let builtSlabTileID: UInt16  // iconMap[iconMap[.concreteSlab] + 2]
    public let wallTileID: UInt16       // iconMap[iconMap[.walls]]

    public init(iconMap: Formats.IconMap)

    public func landscapeType(
        groundTileID: UInt16,
        overlayTileID: UInt16,
        hasStructure: Bool
    ) -> LandscapeType
}
```

The `landscapeType(...)` method exactly mirrors OpenDUNE's `Map_GetLandscapeType`:

```
if ground == builtSlab                       → .concreteSlab
if ground == bloom || ground == bloom+1      → .bloomField
if wall < ground < wall+75                   → .wall
if overlay == wall                           → .destroyedWall
if hasStructure                              → .structure
spriteOffset = ground - landscapeTileID
if spriteOffset < 0 or > 80                  → .entirelyRock (fallback)
return _landscapeSpriteMap[spriteOffset]
```

`_landscapeSpriteMap` is an 81-entry `[LandscapeType]` table we copy verbatim from `map.c`. Lives in `LandscapeLookup.swift` as a `static let` so the hot-path query is a pure array lookup.

## 3. Map construction from a scenario

```swift
public extension Map {
    /// Builds an empty 64×64 map seeded with a scenario's
    /// `[MAP]` field — spice blobs and initial blooms.
    static func empty() -> Map
    mutating func applyMapField(_ field: Scenario.MapField, resolver: TileResolver)
}
```

`applyMapField` stamps the spice `Field` and `Bloom` values onto the grid at their packed positions. We don't procedurally seed the landscape terrain itself yet (`Seed` → perlin-ish generator) — that's a P3 concern and needs OpenDUNE's PRNG to match exactly.

## 4. Testing

`Core/Tests/DuneIICoreTests/MapTests.swift`:

1. `Map.width == 64`, `Map.height == 64`, cells initialise to zero.
2. `TileResolver` classifies a known ground tile ID as the right `LandscapeType` (synthetic `IconMap` with a fake landscape group).
3. A tile whose ground matches `builtSlabTileID` returns `.concreteSlab`.
4. A tile whose ground is inside the wall range returns `.wall`.
5. `applyMapField` places the Atreides mission 1 seeds at the right packed positions.
6. Real `ICON.MAP` + a synthetic scenario field yields sensible landscape classifications for the initial spice fields.

## 5. Related insights

- [format-iconmap-double-indirection](../Insights/format-iconmap-double-indirection.md) — `TileResolver` computes the four magic tile IDs from the indirection.
