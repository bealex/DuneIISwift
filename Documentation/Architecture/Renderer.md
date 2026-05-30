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

- **`FrameComposer`.** Pure. `terrainBuffer(_ frame:, source:)` composites the 64×64 ground-tile layer into a `sidePx × sidePx` (16·64 = 1024) **indexed** buffer (structures are already baked into the ground tiles, so this draws buildings too). `sprites(_ frame:, source:)` resolves each unit's body + turret and each effect (explosion / smoke) into `ComposedSprite`s — the indexed frame, the **image-space** centre (`pos · tileSize / 256` + the `SpriteLayer` pixel offset), the flip, the house (for recolour; `nil` for effects), and a z order (body 1 < turret 2 < effect 3). Colorization is deferred to the leaf so the composer needs no palette.

- **`SpriteKitRenderer`** *(next block — the visual leaf).* Colorizes the terrain buffer (`IndexedImage` + the palette / `PaletteAnimator`) into one nearest-filtered `SKSpriteNode`, and each `ComposedSprite` (house-recoloured via `HouseRemap`, index 0 transparent) into a sprite node, in a camera-scrollable/zoomable scene. Mirrors the existing `mapview` `MapScene`, but driven by `FrameInfo` instead of reaching into `GameState`. Hosted + visually confirmed in an app.

## Conventions

- **Base tile size is 16px** (the native `ICON.ICN` tile), and the world image is the full 64×64 map (1024×1024). Zoom + viewport scroll are a **camera transform** over that image (as `mapview` does today), not a re-composite — so the `SpriteLayer` pixel offsets (turret nudges, the −14px smoke lift) apply directly at the base scale, and `FrameInfo.viewportX/Y` positions the camera.
- **Image space is y-down** (top-left origin); SpriteKit's scene is y-up, so the leaf flips `y` (`sidePx − centerY`), exactly as `MapScene` does.

## Known gaps (documented, not bugs)

- **Sandworm shimmer.** `FrameInfo` omits `blurTile` units, so the composer can't reproduce the `DRAWSPRITE_FLAG_BLUR` sand displacement `mapview` bakes in. Carrying worms through the seam (as a distinct "blur" entity) is deferred.
- **Tile overlays.** `FrameInfo.Tile.overlaySpriteIndex` is carried but not yet composited (the existing apps draw ground only and pass their visual checks). Compositing overlays (spice density, wall joins) is a later refinement.
