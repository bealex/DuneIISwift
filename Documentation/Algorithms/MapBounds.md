# Map bounds (the scenario's playable rectangle)

OpenDUNE's `g_map` is always a fixed **64×64** grid, but each scenario only uses a sub-rectangle of it — the **playable / visible area**. The rest is an unused border that the player can never scroll to and that the game never draws as part of the battlefield.

## Source of truth

`[BASIC] MapScale` (`scenario.c:40`, default `0`) selects one of three fixed rectangles, `g_mapInfos[3]` (`map.c:57`):

| `MapScale` | `minX` | `minY` | `sizeX` | `sizeY` | playable tiles |
|---|---|---|---|---|---|
| 0 | 1 | 1 | 62 | 62 | `[1,63) × [1,63)` (a 1-tile border) |
| 1 | 16 | 16 | 32 | 32 | `[16,48) × [16,48)` |
| 2 | 21 | 21 | 21 | 21 | `[21,42) × [21,42)` |

A tile `(x,y)` is in-bounds iff `minX ≤ x < minX+sizeX && minY ≤ y < minY+sizeY` — this is `Map_IsValidPosition` (`map.c:320`), which OpenDUNE uses to gate **gameplay**: unit/structure spawn + placement, scenario-load unit culling, target search. We already port this (`MapPrimitives.isValidPosition`, `MapInfo.scales`).

The viewport scroll is also clamped to the rectangle (`Map_MoveDirection`, `map.c:77`: `x` clamped to `[minX, minX+sizeX-15]`, `y` to `[minY, minY+sizeY-10]` for the 15×10-tile original viewport) — so in the original you simply can never see outside it.

## What we add: the *rendering* + *camera* boundary

Gameplay already respects the rectangle. The gap was presentation — our free-camera client drew the whole 64×64 and let the camera pan over the unused border. Now:

- **`FrameInfo.mapArea`** (Contracts) carries the playable rectangle (tile coords). `Simulation.makeFrameInfo()` fills it from `MapInfo.scales[mapScale]`; it defaults to the full `64×64` for directly-constructed frames.
- **`FrameComposer`** draws nothing outside it: a terrain cell outside `mapArea` is filled with the border-black index (`borderColourIndex`, the same colour-12 black OpenDUNE fills fog with), unconditionally (independent of `showFog`); and a unit / effect sprite whose tile is outside `mapArea` is culled. So no renderer (duneii / mapview / scenariolab) ever paints the border.
- **The duneii camera** (`Viewport.area`) clamps pan/zoom to the rectangle's world-point bounds and recenters on it when a scenario loads, so navigation "follows the map boundary." When the view is larger than the playable area (zoomed out past 1:1) the area is pinned centred, the surround left black.

### The decorative border margin (2026-06-06)

The camera clamp is **outset by `Viewport.borderPx` (50 game-pixels)** in every direction (`Viewport.clamp` clamps to `area.insetBy(-50)`), so the player can scroll ~50px past the map edge. That margin is filled with a **decorative Dune border ring** instead of black: `GameScene.updateBorder` lays four tiled `SKSpriteNode` strips (top/bottom span the corners, left/right fill the height) just outside `Viewport.area`, on a `borderLayer` at z 0.5 (above the black terrain-border cells, below units; never overlapping the play area). The fill is the **red/gold diagonal hazard stripe from `SCREEN.CPS`** — an 8×8 tileable patch at (241,100), decoded + cropped by `AssetStore.borderTile()` and tiled per strip via `IndexedImage`. Rebuilt only when the playable area changes (per scenario). Client-only (both `duneii` + `duneii-ios`); the headless renderers (mapview/scenariolab/render goldens) don't draw it. Manual-verification owed (GUI; no `ClientTests`).

### Golden-neutrality

The render-golden crops all sit **inside** their scenario's playable area (SCENA001 is `MapScale=1` → `[16,48)`, crops at x∈[26,40)/y∈[21,33); SCENA005 is `MapScale=0` → `[1,63)`, crop inside), so blacking the border changes no committed reference. The simulation/`Scenario` goldens are unaffected (this is presentation only).
