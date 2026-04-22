# Minimap

Colour-per-tile radar render of the live `ScenarioRuntime.tileGrid` + unit / structure pools, rendered into the right-hand sidebar between the BUILD rows and the INFO panel. Refreshed every scheduler tick (≈12 Hz at 60 fps).

Our own feature — OpenDUNE's minimap lives in a separate UI subsystem we haven't ported. This is a minimal port-friendly rewrite: one coloured pixel per map tile, units / structures overlaid in their owner's house colour.

## Contract

- Fixed 64×64 pixel output buffer (`[UInt8]` RGBA, `4 * 64 * 64 = 16384` bytes).
- Pure function of `(tileGrid, landscapeAt, units, structures, houseColor)`. No Foundation date / clock reads; no AppKit / SpriteKit / ImageIO dependencies.
- Terrain colour picked per-tile from the tile's `LandscapeType`. `landscapeAt` is a closure over the scene's `TileResolver` so the pure core doesn't import rendering.
- Unit overlay: one pixel at `(positionX / 256, positionY / 256)` per used unit slot, painted with the unit's house colour. Projectile / bullet types (18..24) are skipped — they'd flicker in/out every tick.
- Structure overlay: every tile in each used structure's footprint (`Simulation.Structures.footprintTiles`) painted with the house colour. Walls and slabs are skipped — they already read as terrain on the minimap, no need for a house-colour overlay.
- Structures paint **after** units so the larger footprints don't vanish behind a unit dot; units painted before structures feels right in practice because the player rarely has a unit parked inside their own building on mission 1.

## Pixel layout

Buffer is row-major, top-left origin (same convention as `tileGrid`): `byte[y * 64 * 4 + x * 4 + 0]` is the R byte of the pixel at tile `(x, y)`. Matches `CGImageFactory.makeRGBAImage(bytes:width:height:)` with `premultipliedLast` alpha — which the scene uses to turn the buffer into an `SKTexture`.

## Terrain palette

Values chosen to stay readable at the sidebar size (120×120 pt, nearest-neighbour upscaled from 64 px). No claim to visual parity with OpenDUNE's radar — we don't yet have its palette.

| LandscapeType | Colour (hex) | Rationale |
|---|---|---|
| normalSand, partialDune, entirelyDune | `#C8A664` | Warm sandy yellow. |
| partialRock, entirelyRock, mostlyRock | `#807056` | Desaturated rock / stone. |
| partialMountain, entirelyMountain | `#5C4A36` | Darker rock. |
| spice | `#E89024` | Spice orange. |
| thickSpice | `#D46818` | Deeper spice. |
| concreteSlab | `#A0A0A0` | Light grey — player-placed concrete reads as a distinct neutral. |
| wall, destroyedWall | `#707070` | Medium grey. |
| structure | handled by the per-structure overlay, but base fallback `#555555` |
| bloomField | `#B89058` | Same warm brown as sand; blooms are tiny anyway. |

## House colours on the minimap

Pulled from `HouseColors.color(for:)` but converted to the minimap's `ColorRGBA` value type inside the scene wiring. The pure renderer accepts a `(UInt8) -> ColorRGBA` closure so tests can inject deterministic colours.

## Why every tick

Units and structures move / get created every tick. Regenerating the buffer each tick is cheap: 16 KB of RGBA + one `CGImage` alloc + one `SKTexture` assignment. No incremental update logic — simpler and avoids stale-state bugs.

## Layout in `ScenarioScene`

```
+--------------------------+
| BUILD header             |
| ...build rows (32pt ea)..|  y ≈ mapSize - 36 down to ~324
|                          |
| [minimap 120×120 pt]     |  y ≈ 204 .. 324
|                          |
| INFO panel (200 pt tall) |  y = 0 .. 200
+--------------------------+
```

Constants live in a private `MinimapPanel` enum on `ScenarioScene`, matching the `InfoPanel` precedent.

## Refresh sites

- `build()` — initial render after the scene is loaded so the minimap isn't a black square before the first tick fires.
- `update(_:)` — every `framesPerTick` frames, alongside `syncVisualsFromPool` / `refreshHud`. Guarded behind `scheduler != nil` like the rest of the tick work.

## Tests

Pure-function coverage in `Core/Tests/DuneIICoreTests/MinimapTests.swift`:

1. Buffer length = `4 * 64 * 64` = 16384.
2. Every pixel alpha = 0xFF.
3. A uniform sand grid with no units / structures yields the sand colour at every pixel.
4. A single unit at tile `(5, 10)` paints the house colour at that one pixel.
5. A refinery (3×2) footprint paints 6 pixels with the house colour.
6. A freed unit slot doesn't paint.
7. Projectile unit types (18..24) are skipped.
8. Spice tiles render as spice colour, thick spice as thick-spice colour.
9. Structures paint on top of units (footprint doesn't get "holes" from overlapped unit pixels).

Visual correctness of the scene integration can't be asserted from CI (SpriteKit sandbox); a short manual-verification checklist lives at the end of the history entry.
