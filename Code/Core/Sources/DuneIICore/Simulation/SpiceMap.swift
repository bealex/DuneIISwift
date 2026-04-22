import Foundation

extension Simulation {
    /// Runtime mutable spice state over the 64×64 world. Each tile
    /// carries a `SpiceLevel` — {bare, thin, thick} — corresponding to
    /// OpenDUNE's `LST_NORMAL_SAND` / `LST_SPICE` / `LST_THICK_SPICE`
    /// on the baseline map. This separates "is there spice here" from
    /// the on-disk `Tile.groundTileID` so we can mutate during a run
    /// without rewriting the baseline map.
    ///
    /// Slice 4 of the harvester / spice-income bridge. Consumed by
    /// `Simulation.Units.harvestSpiceStep`'s `changeSpice` closure —
    /// the scene wires that closure to `SpiceMap.apply(delta:at:)` when
    /// the harvest AI slice lands.
    ///
    /// Design note: transition rules mirror `Map_ChangeSpiceAmount`
    /// (`src/map.c:771..797`). A single negative-delta call moves
    /// THICK → THIN or THIN → BARE; positive moves BARE → THIN or
    /// THIN → THICK. Repeat-apply is gated (THICK stays THICK on +1;
    /// BARE stays BARE on −1). `Map_FixupSpiceEdges` (visual smoothing
    /// of neighbour tiles) is a rendering concern and lives in a later
    /// scene-side slice; the sim-layer state machine tracks only the
    /// four values {bare, thin, thick} plus an impassable "not sand"
    /// terminal for mountain / rock / water / structure tiles.
    public struct SpiceMap: Sendable, Equatable {
        public static let width = 64
        public static let height = 64
        public static let cellCount = width * height

        public enum Level: UInt8, Sendable, Equatable {
            /// Neither sandy nor dune — can't host spice, apply is a no-op.
            case notSand = 0
            case bare = 1
            case thin = 2
            case thick = 3
        }

        public private(set) var cells: [Level]

        public init() {
            self.cells = Array(repeating: .bare, count: Self.cellCount)
        }

        /// Build from a `WorldSnapshot.Tile` grid (64×64). The caller
        /// supplies a `landscapeAt: (Int) -> LandscapeType` closure —
        /// typically `{ i in resolver.landscapeType(...) }` at the
        /// scene layer; tests pass a stub. `.spice` → `.thin`,
        /// `.thickSpice` → `.thick`, sandy / dune → `.bare`, else
        /// `.notSand` so `apply` can short-circuit.
        public init(
            cellCount: Int = Self.cellCount,
            landscapeAt: (Int) -> LandscapeType
        ) {
            precondition(cellCount == Self.cellCount, "SpiceMap size mismatch")
            var result = [Level](repeating: .notSand, count: cellCount)
            for i in 0..<cellCount {
                switch landscapeAt(i) {
                case .spice:      result[i] = .thin
                case .thickSpice: result[i] = .thick
                case .normalSand, .entirelyDune, .partialDune:
                    result[i] = .bare
                default:
                    result[i] = .notSand
                }
            }
            self.cells = result
        }

        public subscript(packed: UInt16) -> Level {
            get { cells[Int(packed)] }
        }

        public subscript(x: Int, y: Int) -> Level {
            get { cells[y * Self.width + x] }
        }

        /// Mirror of OpenDUNE's `Map_ChangeSpiceAmount(packed, dir)`.
        /// `delta < 0` drains; `delta > 0` adds; `delta == 0` is a
        /// no-op.
        ///
        /// Returns the level after the call (same as before when the
        /// call was a no-op by gate).
        ///
        /// Gates ported from `src/map.c:779..781`:
        /// - THICK + positive → no-op.
        /// - non-spice + negative → no-op.
        /// - BARE / non-sand + positive → no-op (must be sandy to
        ///   host spice).
        ///
        /// Every transition logs under the `spicemap` tracer so a
        /// trace file captures the drain/regrow cadence.
        @discardableResult
        public mutating func apply(delta: Int16, at packed: UInt16) -> Level {
            guard Int(packed) < Self.cellCount else { return .notSand }
            if delta == 0 { return cells[Int(packed)] }
            let before = cells[Int(packed)]
            switch before {
            case .notSand:
                return before
            case .thick:
                if delta > 0 { return before }  // already max
                cells[Int(packed)] = .thin
            case .thin:
                cells[Int(packed)] = delta > 0 ? .thick : .bare
            case .bare:
                if delta < 0 { return before }  // already min
                cells[Int(packed)] = .thin
            }
            let after = cells[Int(packed)]
            let tileX = Int(packed) % Self.width
            let tileY = Int(packed) / Self.width
            Log.info(
                "spicemap tile=(\(tileX),\(tileY)) packed=\(packed) \(before)→\(after) delta=\(delta)",
                tracer: .label("spicemap")
            )
            return after
        }

        /// Bridge for `harvestSpiceStep`'s `landscapeAt` closure —
        /// returns the `LandscapeType.rawValue` matching the current
        /// spice level, or a sentinel `normalSand` for notSand / bare
        /// tiles (callers only care about the spice vs not-spice
        /// distinction).
        public func landscapeByte(at packed: UInt16) -> UInt8 {
            guard Int(packed) < Self.cellCount else { return UInt8(LandscapeType.normalSand.rawValue) }
            switch cells[Int(packed)] {
            case .thick: return UInt8(LandscapeType.thickSpice.rawValue)
            case .thin:  return UInt8(LandscapeType.spice.rawValue)
            case .bare, .notSand: return UInt8(LandscapeType.normalSand.rawValue)
            }
        }
    }
}
