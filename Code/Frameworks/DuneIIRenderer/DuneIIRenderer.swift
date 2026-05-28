/// Rendering: a `Renderer` protocol plus a Foundation-only `NullRenderer`, and (later) a
/// `SpriteKitRenderer` with reusable sprite/animation drawing services.
///
/// Renders pixel-faithful world content from a `FrameInfo` snapshot, upscaled into a resizable
/// window. Depends only on `DuneIIContracts` (the frame snapshot) and `DuneIIFormats` (assets) —
/// never on the simulation. The protocol + null implementation land once `FrameInfo` exists
/// (Phase 2/4); the SpriteKit implementation arrives in Phase 4. See `Documentation/Plan.v1.md`.
public enum DuneIIRenderer {}
