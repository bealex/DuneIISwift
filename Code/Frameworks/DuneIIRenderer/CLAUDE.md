# DuneIIRenderer

Rendering. Depends on `DuneIIContracts` (the `FrameInfo` snapshot) + `DuneIIFormats` (assets). Never depends on the simulation.

A `Renderer` protocol with a Foundation-only `NullRenderer` (for headless/tests) and a `SpriteKitRenderer` (Mac Catalyst). Renders pixel-faithful world *content* from a `FrameInfo` snapshot, upscaled (nearest-neighbor) into a resizable, scalable window. Also exposes reusable sprite/animation drawing services used by the UI panels and the `rendertest` app.

The protocol + `NullRenderer` land once `FrameInfo` exists (Phase 2/4); the SpriteKit implementation and `rendertest` are Phase 4. SpriteKit/Catalyst code is `@available(macCatalyst 26.0, *)`. See `Documentation/Plan.v1.md` §4.6–4.7.
