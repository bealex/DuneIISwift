# DuneIIRenderer

Rendering. Depends on `DuneIIContracts` (the `FrameInfo` snapshot) + `DuneIIFormats` (assets). Never depends on the simulation.

Present today (the asset rendering services used by the `rendertest` app):
- `HouseRemap` — house color recolor of palette indices, ported from OpenDUNE (`gui/viewport.c:300` for sprites: lookup entries `0x90...0x98` shift by `houseID << 4`; `gfx.c:224` for tiles: the whole `0x90...0x9F` block). The 1.07 path (no enhanced clamp).
- `IndexedImage` — colorize indexed pixels through a `Palette` (with an optional per-index `remap` for house recoloring and a transparent index) into a `CGImage` at native size, unsmoothed. Display-time nearest-neighbor scaling is the consumer's job.

Imports CoreGraphics (fine for `swift build`). Still to come: the `FrameInfo`-driven world renderer (a `Renderer` protocol + `NullRenderer` + a `SpriteKitRenderer`) once `FrameInfo` and the simulation exist — Phase 4 proper. See `Documentation/Plan.v1.md` §4.
