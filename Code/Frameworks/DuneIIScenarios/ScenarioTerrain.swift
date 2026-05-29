import DuneIIWorld

/// A passable tile kind for the test terrain. Both classify (via `groundTileID`) to a passable
/// `LandscapeType` — `sand` → `normalSand`, `rock` → `entirelyRock` — differing only in movement cost.
public enum TerrainKind: UInt8, Sendable, Equatable {
    case sand = 0
    case rock = 1
}

/// A deterministic 8×8 sand/rock terrain placed at a valid interior offset of the 64×64 map. Reproducible
/// from `seed` (a small LCG over the 64 tiles), so a scenario built from it is bit-for-bit comparable
/// against the oracle. See `Documentation/Architecture/ScenarioHarness.md`.
public struct ScenarioTerrain: Sendable, Equatable {
    public static let size = 8

    public let seed: UInt32
    public let originX: Int
    public let originY: Int
    public let kinds: [TerrainKind]   // 64 tiles, row-major: kinds[ly * size + lx]

    public init(seed: UInt32, originX: Int = 1, originY: Int = 1) {
        self.seed = seed
        self.originX = originX
        self.originY = originY

        // A plain LCG, mixed with the seed, gives a reproducible sand/rock layout (and is trivial to
        // reproduce in the C oracle harness). One bit per tile.
        var s: UInt32 = seed &* 2_654_435_761 &+ 1
        var k: [TerrainKind] = []
        k.reserveCapacity(Self.size * Self.size)
        for _ in 0 ..< Self.size * Self.size {
            s = s &* 1_103_515_245 &+ 12_345
            k.append((s >> 16) & 1 == 0 ? .sand : .rock)
        }
        kinds = k
    }

    public func kind(lx: Int, ly: Int) -> TerrainKind { kinds[ly * Self.size + lx] }

    /// The packed 64×64 map tile for a local 8×8 coordinate.
    public func mapPacked(lx: Int, ly: Int) -> UInt16 {
        UInt16((originY + ly) * 64 + (originX + lx))
    }

    /// Fill the whole map with sand, then stamp the 8×8 region per `kinds`. Requires `state.tileIDs`
    /// (the landscape base) to be set already.
    public func apply(to state: inout GameState) {
        let sand = state.tileIDs.landscape &+ 0    // offset 0 → normalSand
        let rock = state.tileIDs.landscape &+ 16   // offset 16 → entirelyRock

        for i in 0 ..< state.map.count {
            var t = MapTile()
            t.groundTileID = sand
            state.map[i] = t
        }
        for ly in 0 ..< Self.size {
            for lx in 0 ..< Self.size {
                let p = Int(mapPacked(lx: lx, ly: ly))
                state.map[p].groundTileID = kind(lx: lx, ly: ly) == .sand ? sand : rock
            }
        }
    }
}
