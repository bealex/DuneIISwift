# Renderer — consuming `FrameInfo` (Phase 4)

`DuneIIRenderer` turns a `FrameInfo` snapshot into pixel-faithful world content. It is split into a **pure, headless-testable compositing core** and a thin **SpriteKit presentation leaf**, so the parity-relevant logic (which sprite, where, flipped, recoloured) is unit-tested without a window, and only the SpriteKit/Catalyst glue is left visual-only.

```
FrameInfo ──► FrameComposer ──► (terrain index buffer, [ComposedSprite]) ──► SpriteKitRenderer ──► SKScene
              (pure)             indexed pixels + placements                  (colorize + nodes)
                  ▲
                  │ pixels via
              WorldSpriteSource  (terrainTile(id), unitFrame(globalIndex), terrainTileSize)
```

## Pieces

- **`Renderer` protocol + `NullRenderer`.** The consumer seam: `mutating func render(_ frame: FrameInfo)`. `NullRenderer` records `lastFrame` (so a headless test can assert the sim drove a frame through) and draws nothing — the test/oracle path and the precondition for testing panels against recorded frames.

- **`GlobalSprite`.** The one canonical home of the `Sprites_Init` load-order mapping (a global unit/effect sprite index → its SHP sheet + local frame: UNITS2 @ 111, UNITS1 @ 151, UNITS @ 238). Previously copy-pasted in `mapview`/`scenariolab`; deduped here. Pure + golden-tested against the bases.

- **`WorldSpriteSource`.** The asset abstraction the composer needs, so the composer stays pure and asset-loading stays app-side: `terrainTileSize` (16), `terrainTile(_ id:) -> [UInt8]?` (a 16×16 `ICON.ICN` tile), `unitFrame(globalIndex:) -> SpriteFrame?` (a UNITS-sheet frame). Implementations use `GlobalSprite` + their own SHP/ICN stores.

- **`FrameComposer`.** Pure. `terrainBuffer(_ frame:, source:)` composites the 64×64 ground-tile layer into a `sidePx × sidePx` (16·64 = 1024) **indexed** buffer (structures are already baked into the ground tiles, so this draws buildings too). `sprites(_ frame:, source:)` resolves each unit's body + turret (+ the harvester harvesting overlay) and each effect (explosion / smoke) into `ComposedSprite`s — the indexed frame, the **image-space** centre (`pos · tileSize / 256` + the `SpriteLayer` pixel offset), the flip, the house (for recolour; `nil` for effects + the overlay), and a z order. The z bands mirror `viewport.c`'s draw passes: ground-unit body (1) < harvest overlay (2) < turret (3) < explosions/smoke (4) < air-unit body (5) < air-unit turret (6) — i.e. **air units (wingers: carryall/ornithopter/frigate/missiles) draw last, on top of everything**, and explosions sit above ground units but below air units. `FrameInfo.Unit.isAirUnit` selects the air band; `makeFrameInfo` skips `isNotOnMap` (hidden / in-transport) units entirely, as `viewport.c` does. Colorization is deferred to the leaf so the composer needs no palette.

- **`SpriteKitRenderer`** *(the visual leaf — implemented, prerendered/cached).* `@MainActor`; realizes the `Renderer` seam shape (`render(_:)` per frame) without a formal conformance, so the headless seam stays actor-agnostic. **Hosted in `mapview`:** `MapScene` advances the `Simulation`, snapshots `makeFrameInfo()`, and hands it to the renderer each frame (replacing the old `MapImageBuilder` that reached into `GameState`); the app-side `MapSpriteSource` provides the assets. **Everything that can be pre-rendered is cached** so the steady-state per-frame path does almost no CoreGraphics work (the profiled hotspots were the per-frame full-map `terrainBuffer` + the megapixel `IndexedImage.cgImage`, plus a `cgImage` per sprite per frame):
  - **Terrain is layered.** The static landscape is composited + colorized **once** into one background `SKSpriteNode`. Only cells that change over time get a small 16×16 overlay node on top: cells whose **appearance** — `(ground, overlay, house)` — changes (structure animations, a destroyed building reverting to landscape, a wall overlay, a tile veiling/unveiling) and cells that use the **cycling wind-trap colour** (palette index 223). Each frame only the dirty cells are touched.
  - **Each cell composes ground + overlay + fog** (`FrameComposer.cell`): the ground tile (house-recoloured if owned), with a non-veil overlay tile (walls) blitted opaquely on top, or — when the overlay is the veil id (`FrameInfo.veiledTileIndex`) and **fog display is on** — a solid black cell (colour 12, `viewport.c:390`). **Fog is a toggle** (`SpriteKitRenderer.showFog`, default off): the verification UI shows the whole landscape (OpenDUNE's "debug scenario" view), and flipping it on (mapview's *Fog* toolbar toggle → `rebuildTerrain`) blacks out veiled cells so reveal behaviour can be verified. (Our fog model is binary — veiled vs clear — not the original's partial-fog edge sprites.)
  - **Textures are cached by appearance.** A `(tileId, overlayId, house, windColour, fog)` tile texture and a `(spriteIndex, house)` sprite texture are colorized once and reused (the horizontal flip is baked into the sprite texture). Palette-cycle variants accumulate, so after the first cycle nothing is recolorized. Sprite nodes are **pooled** (repositioned + re-textured, never reallocated). Memory-heavy by design.

  This proves the seam end-to-end on real `SCEN*.INI` scenarios.

- **Headless capture (`SpriteKitRenderer.snapshot(_:crop:)`).** The *same* renderer renders a `FrameInfo`
  into an off-screen `SKScene` and rasterizes it (`SKView.texture(from:)` → `CGImage`), optionally cropped
  to an image-space rect (top-left, y-down — tile `(tx,ty)·ts`). This is the real pipeline (same
  nodes/textures/z-order/palette/fog), not a parallel rasterizer, so a **headless run can pause at any tick
  and snapshot any region** for a rendering test or a reference PNG. The intended flow: keep a
  `NullRenderer` for the run (fast, draws nothing), and swap in a dedicated `SpriteKitRenderer` only to
  capture (a node has one parent, so a capture renderer must not also be `attach`ed to a live scene).
  Capture is **GPU-backed** — it runs under `swift test` / a tool on a real Mac (which has a GPU), and
  returns `nil` on a no-GPU box. The per-pixel composition it captures is itself covered headlessly by the
  `FrameComposer`/`FrameInfo` tests (no GPU needed). **Backing scale:** `texture(from:)` rasterizes at the
  host's backing scale (2× on a Retina display), so the returned `CGImage` is larger than the logical world
  (`worldSidePx`); `snapshot` scales the logical-point `crop` rect to pixels by the measured ratio before
  `cropping(to:)`, so a crop captures the requested tile region at any backing scale (the un-cropped image
  is returned at native resolution).

- **`DecodedSpriteSource`** — a reusable value-type `WorldSpriteSource` over decoded assets (`Icn.TileSet`
  + the UNITS `Shp.FrameSet`s keyed by file, addressed via `GlobalSprite`). `mapview`'s `MapSpriteSource`
  now just adapts its `@MainActor` `AssetStore` into one; a headless capture / test constructs it from
  whatever loader it has.

- **Render-golden harness (`RenderGoldenTests`).** The auto-test payoff of `snapshot` and the Phase-4 DoD
  *"diff a rendered frame pixel-exact against a reference PNG."* Each case (`RenderHarness.Case`: scenario +
  tick + optional tile-space crop + fog) runs the scenario through the **real** `Simulation`, captures the
  region through the **real** `SpriteKitRenderer.snapshot`, and diffs it byte-for-byte against a committed
  reference (`Tests/RenderGoldenTests/Fixtures/<name>.png`) via `PngImage` (RGBA8 decode + per-channel diff,
  reporting mismatch count / first-pixel / max Δ). **One capture path** records and diffs: with
  `DUNEII_RENDER_RECORD=1` a case *writes* its reference (so the reference is exactly what the renderer
  produces), without it the case *diffs* a fresh capture — `Scripts/gen-render-goldens.sh` records. Adding a
  case is one line in the `cases` table + a re-record. It short-circuits (passes) when the install or an
  off-screen GPU context is absent. Pixel-exactness holds run-to-run on a given host; the references are
  captured at the host backing scale, so the harness is a same-host (dev Mac / consistent CI) regression
  guard, not a cross-GPU oracle.

## Conventions

- **Base tile size is 16px** (the native `ICON.ICN` tile), and the world image is the full 64×64 map (1024×1024). Zoom + viewport scroll are a **camera transform** over that image (as `mapview` does today), not a re-composite — so the `SpriteLayer` pixel offsets (turret nudges, the −14px smoke lift) apply directly at the base scale, and `FrameInfo.viewportX/Y` positions the camera.
- **Image space is y-down** (top-left origin); SpriteKit's scene is y-up, so the leaf flips `y` (`sidePx − centerY`), exactly as `MapScene` does.

## Known gaps (documented, not bugs)

None outstanding for the world content. Fog (soft edges), overlay transparency, and the sandworm shimmer are implemented (below). The renderer draws the whole-map "debug scenario" view by default; the in-game HUD/menus are deliberately not reproduced (the verification UI is our own).

## Fog of war, overlay, and sandworm compositing (faithful)

**Overlay transparency.** A non-veil overlay (a wall — `overlayTileID == g_wallTileID`) is composited **over** the ground with index-0 transparency (only its non-zero pixels overwrite), not blitted opaquely — matching `GFX_DrawTile` (`gfx.c:210`: `if (icon_palette[0] == 0)` → skip colour 0). `FrameComposer.cell` does this.

**Partial fog edges.** The sim models fog as binary (`isUnveiled` per tile), but the renderer derives the original's soft edge: `makeFrameInfo` computes each revealed tile's 4-neighbour veil bitmask (`Simulation.fogEdgeMask`, mirroring `Map_UnveilTile_Neighbour`, `map.c:1293`; bit 0 = N, 1 = E, 2 = S, 3 = W) and picks the fog-edge sprite `TileIDs.fogEdges[mask]` (the FOG_OF_WAR icon-group tiles 0–15, hoisted into `GameState` like `tileIDs.veiled`). It carries this in a **separate** `FrameInfo.Tile.fogEdgeSpriteIndex` — separate from `overlaySpriteIndex` because that slot holds walls (always shown) while fog edges are gated by the renderer's `showFog` toggle. `FrameComposer.cell` composites the fog edge over the ground (same colour-0 transparency) only when `showFog` is on; a fully-veiled tile is still a solid black square (`overlaySpriteIndex == veiledTileIndex`). Covered by `FrameInfoTests` (`fogEdgeMask`/`fogEdges`) + `FrameComposerTests` (`fogEdgeComposition`); the `scena001-base-fog-t60` render-golden locks the dithered soft edge.

**Sandworm shimmer (`DRAWSPRITE_FLAG_BLUR`).** A sandworm isn't a normal SHP draw: OpenDUNE writes `*buf = buf[blurOffset]` for each opaque worm-sprite pixel (`gui.c:1289`), so inside the worm's silhouette the terrain is **displaced horizontally** by a few pixels (an animated heat-haze; the offset cycles `blurOffsets = {1,3,2,5,4,3,2,1}` per frame). The pure indexed compositor can't do this (it caches terrain + sprites as separate textures), so it is realized as a **CoreGraphics effect in the leaf**: `makeFrameInfo` carries `blurTile` units in a separate `FrameInfo.blurs` (each with its silhouette sprite + position, not in `units`); `ShimmerEffect.patch` builds a worm-sized `CGImage` that samples the colorized terrain `offset` columns to the right within the worm mask (transparent outside), and `SpriteKitRenderer` lays it on a blur layer above the terrain, advancing the offset each frame. A still capture is subtle (the original shimmer is visible mainly in motion); the displacement itself is unit-tested by `ShimmerEffectTests`, the blur emission by `FrameInfoTests` (`sandwormBlur`), and the `scena001-worm-t0` render-golden locks a worm over the rock/sand boundary. Approximation: it samples the *static* colorized terrain (worms cross open sand), not the live framebuffer.

**Winger drop shadow (`REMAP | BLUR` with `g_paletteMapping1`).** A `hasShadow` air unit (carryall, ornithopter, frigate — the rockets/sonic do **not**) draws its body silhouette a second time at `(x+1, y+3)` before the body (`viewport.c:736`). That draw (`gui.c:1303`) ignores the sprite's own colours: for each opaque silhouette pixel it remaps the **background** pixel underneath through `g_paletteMapping1` — a darkening LUT that blends every colour ~33% toward the dark reference colour `0xC` (`GUI_Palette_CreateMapping(g_palette1, …, 0xC, 0x55)`, `opendune.c:959`, with `[0xFF]/[0xDF]/[0xEF]` kept identity). So the shadow is the body's shape darkening whatever it covers. Like the shimmer, the pure compositor can't read the background, so it is a **CoreGraphics effect**: `ShadowMapping.table` ports the LUT (built once from the base palette — OpenDUNE never rebuilds it on a palette cycle), and `ShadowEffect.patch` samples the colorized terrain buffer under the silhouette and remaps each covered pixel. **Buildings are baked into the terrain tile layer** (`Structure_UpdateMap`), so this darkens both terrain *and the building beneath an aircraft* — the "crash site over a building looked weird" was the shadow being absent entirely. `SpriteKitRenderer` lays the patch on a shadow layer (z 3) **above the terrain/buildings but under every unit sprite**, so a winger's body draws over its own shadow. `FrameInfo.Unit.hasShadow` (set from `ObjectInfo.hasShadow`) selects the unit. Unit-tested by `ShadowEffectTests` (the LUT blend + the masked darkening + fog suppression); the `scena005-air-shadow-t0` render-golden locks an ornithopter's shadow over the Harkonnen base, and `airUnitCastsShadow` proves the pass changes pixels vs a no-shadow render. Approximation (shared with the shimmer): it samples the *static* terrain buffer, so a shadow over another **ground unit** darkens the terrain, not that unit (rare; OpenDUNE darkens whatever is on screen).
