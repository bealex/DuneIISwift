/// One drawable sprite layer: a global sprite index into the concatenated game SHPs, an optional
/// horizontal flip, and a pixel offset from the entity's draw origin. Presentation-neutral — the
/// renderer maps the global index to an SHP + local frame via the load-order bases (`Sprites_Init`,
/// `src/sprites.c`); the flip + offset are what OpenDUNE's `viewport.c` computes per orientation.
///
/// The canonical sprite-layer type across the `sim → render` seam: `UnitSprites` (the `viewport.c`
/// port in `DuneIISimulation`) produces these, the renderer and the verification panels consume them.
public struct SpriteLayer: Sendable, Equatable {
    /// The global sprite index (into the concatenated unit/structure SHPs).
    public var spriteIndex: Int
    /// Whether to draw the frame mirrored **horizontally** (the W half of a directional sprite, or an
    /// air unit's left half) — `DRAWSPRITE_FLAG_RTL`.
    public var flipped: Bool
    /// Whether to draw the frame mirrored **vertically** — `DRAWSPRITE_FLAG_BOTTOMUP`. Air units use this
    /// for their southern facings (the southern frames are the northern frames flipped top-to-bottom).
    public var flippedV: Bool
    /// Pixel offset from the entity's draw origin (e.g. a turret's per-orientation nudge).
    public var offsetX: Int
    public var offsetY: Int

    public init(spriteIndex: Int, flipped: Bool = false, flippedV: Bool = false,
                offsetX: Int = 0, offsetY: Int = 0) {
        self.spriteIndex = spriteIndex
        self.flipped = flipped
        self.flippedV = flippedV
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}
