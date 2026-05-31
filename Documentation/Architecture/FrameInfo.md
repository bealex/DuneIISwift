# FrameInfo — the simulation → render seam

`FrameInfo` is the immutable, presentation-neutral snapshot the simulation hands the renderer (and the verification panels) once per drawn frame. It is the `sim → render` half of the Contracts seam (the input half is `Command`, the audio half is `SoundEvent`). It is the precondition for Phase 4: the `SpriteKitRenderer` is a **pure function of a `FrameInfo`** — it never reads simulation internals, so it stays a mockable leaf and can be driven from a recorded snapshot (§4.3/§4.6 of `Plan.v1.md`).

It lives in `DuneIIContracts` (Foundation-only, depends on nothing). The simulation **produces** it (`Simulation.makeFrameInfo()`); renderer/input/audio/UI panels **consume** it. Because it is a value type with no engine types, a panel can be unit-tested against a hand-built `FrameInfo`.

## Coordinate + sprite conventions

- **Positions** are in **world sub-tile units** — the native `tile32` space where one tile is `256` units (`position.x`, OpenDUNE). The renderer converts to screen pixels by `px = pos * tilePx / 256` and subtracts the viewport origin (which is in the same space). This keeps `FrameInfo` independent of the renderer's chosen tile size / zoom.
- **Sprites** are carried as **global sprite indices** into the concatenated game SHPs (the load-order bases `Sprites_Init` derives — UNITS2 @ 111, UNITS1 @ 151, UNITS @ 238 for units; `groundTileID`/`overlayTileID` for terrain). The renderer maps a global index to an SHP + local frame; `FrameInfo` does not name files. A `SpriteLayer` adds the horizontal flip and the per-orientation pixel offset that `viewport.c` computes (e.g. turret offsets).
- **Houses** are the Contracts `HouseID`. A unit's house is the **effective** house (`Unit_GetHouseID` — a deviated unit shows Ordos colours in 1.07), so deviation is visible without the renderer knowing the rule.

## What it carries

| Field | Source | For |
|---|---|---|
| `tick` | `state.timerGame` | game-info |
| `mapWidth`/`mapHeight` (64×64) | constant | renderer terrain layout |
| `tiles` (row-major) | `state.map` | renderer terrain **and structures** (buildings are baked into the ground tiles by `Structure_UpdateMap`, so the terrain layer already draws them) |
| `units` | `state.units` (`.used`, non-`blurTile`) | renderer + inspector |
| `structures` | `state.structures` (`.used`) | inspector/selection (the renderer draws them from `tiles`) |
| `effects` | `state.explosions` (active) + smoke over `.isSmoking` units | renderer transient layer |
| `houses` | `state.houses` (`.used`) | game-info |
| `viewportX`/`viewportY` | `state.viewportPosition` (packed tile → sub-tile units) | renderer scroll origin |

### Per-tile (`FrameInfo.Tile`)
`groundSpriteIndex` (`groundTileID`), `overlaySpriteIndex` (`overlayTileID`, 0 = none — a wall, or the full veil), `isUnveiled` (false = under fog in the player's view), `fogEdgeSpriteIndex` (a partial fog-of-war edge sprite for a revealed tile bordering the unknown — derived by `makeFrameInfo` from the binary `isUnveiled` neighbours via `Simulation.fogEdgeMask`; `0` = none; kept separate from `overlaySpriteIndex` because walls always show while fog edges are gated by the renderer's `showFog`). See `Architecture/Renderer.md` → "Fog of war + overlay compositing".

### Per-unit (`FrameInfo.Unit`)
`id` (pool index), `type` (`UnitType`), `house` (effective), `positionX/Y`, `body` + optional `turret` `SpriteLayer` (from `UnitSprites`, the `viewport.c` port), `isSmoking`, `hitpoints`/`hitpointsMax`. Sandworms (`blurTile`, the shimmer) are omitted — they are not a normal SHP draw.

### Per-structure (`FrameInfo.Structure`)
`id`, `type` (`StructureType`), `house`, `positionX/Y` (the tile **corner**, per `Structure_Place: position &= 0xFF00`), `hitpoints`/`hitpointsMax`, `state` is not surfaced (the assembled icon already reflects it via the tile layer). Carried for the inspector/selection; the renderer draws structures from `tiles`.

### Per-effect (`FrameInfo.Effect`)
`positionX/Y` + a `SpriteLayer`. Two producers: active explosions (the sim drives `explosion.spriteID`, already a global index) and a cycling smoke cloud over each damaged-but-alive vehicle (`180 + (spriteOffset & 3)`, 183→181, drawn 14px above the unit — `viewport.c:615`). Both are global indices into the UNITS SHPs.

### Per-house (`FrameInfo.House`)
`id`, `credits`, `creditsStorage`, `powerProduction`, `powerUsage`.

## Production

`Simulation.makeFrameInfo()` (in `DuneIISimulation`) snapshots the current `GameState`. It does **not** mutate; it is callable any time after a `tick()` (the renderer calls it once per drawn frame, decoupled from the sim cadence). Unit sprite resolution reuses `UnitSprites` (the existing `viewport.c` port). `UnitSpriteLayer` is a typealias of the Contracts `SpriteLayer`, so there is one canonical sprite-layer type across the seam.

## Deliberately out (for now)

Dirty regions / partial-frame deltas (the whole snapshot is cheap enough at 64×64; revisit if profiling shows the copy matters), selection/cursor state (a `Command`/UI concern, not sim state), and the minimap composition (the renderer derives it from `tiles`). These are noted in `Plan.v1.md` §4 as future renderer work, not seam content.
