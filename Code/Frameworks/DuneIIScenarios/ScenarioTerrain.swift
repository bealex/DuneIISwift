import DuneIIFormats
import DuneIIWorld

/// The 8×8 placement window for a `TestScenario`, laid over **real `Map_CreateLandscape` terrain**. The
/// whole 64×64 map is generated from `seed` (natural sand / dune / rock / mountain / spice with the
/// proper transition tiles — the same bit-exact generator the bootstrap golden uses), and the scenario's
/// units + building are placed inside this window, which the lab renders. Reproducible from `seed`.
public struct ScenarioTerrain: Sendable, Equatable {
    public static let size = 8

    public let seed: UInt32
    public let originX: Int
    public let originY: Int

    public init(seed: UInt32, originX: Int = 1, originY: Int = 1) {
        self.seed = seed
        self.originX = originX
        self.originY = originY
    }

    /// The packed 64×64 map tile for a local 8×8 coordinate.
    public func mapPacked(lx: Int, ly: Int) -> UInt16 {
        UInt16((originY + ly) * 64 + (originX + lx))
    }

    /// Generate the natural landscape into `state` from `seed` (`Map_CreateLandscape`). `iconMap` supplies
    /// the landscape sprite group; `state.tileIDs` should already be set (for later unit/structure
    /// placement). Reseeds and advances `state.random256`, as the original generator does.
    public func apply(to state: inout GameState, iconMap: IconMap) {
        state.createLandscape(seed: seed, iconMap: iconMap)
    }
}
