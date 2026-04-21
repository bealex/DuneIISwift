import Foundation

/// Frozen snapshot of a loaded scenario at its initial state. Pairs the
/// static `Scenario` with a stamped `Map` and helper queries the
/// simulation / renderer need at world-build time.
public struct ScenarioWorld: Sendable {
    public let scenario: Scenario
    public let resolver: TileResolver
    public var map: Map

    public init(scenario: Scenario, resolver: TileResolver, iconMap: Formats.IconMap? = nil) {
        self.scenario = scenario
        self.resolver = resolver

        // Stamp the full landscape baseline via the OpenDUNE generator
        // (sand / rock / dune / mountain / spice / thick-spice) before
        // overlaying scenario specials. Without this step every cell
        // starts at tile 0 and the map renders as a flat mono-texture.
        var map = Map.Generator.generate(seed: scenario.mapField.seed, resolver: resolver)
        map.applyMapField(scenario.mapField, resolver: resolver)

        for structure in scenario.structures {
            let tile = structure.position.tile
            let index = Int(tile.y) * Map.width + Int(tile.x)
            if structure.isGenerated && structure.structureType == .slab1x1 {
                map.cells[index].groundTileID = resolver.builtSlabTileID
            } else if structure.isGenerated && structure.structureType == .slab2x2 {
                // 2×2 slab: stamp four cells starting at the anchor.
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let tx = Int(tile.x) + dx
                        let ty = Int(tile.y) + dy
                        guard tx < Map.width, ty < Map.height else { continue }
                        map.cells[ty * Map.width + tx].groundTileID = resolver.builtSlabTileID
                    }
                }
            } else if structure.isGenerated && structure.structureType == .wall {
                map.cells[index].groundTileID = resolver.wallTileID &+ 1
            } else if let iconMap,
                      let groupRaw = Simulation.StructureInfo.iconGroupRawValue(
                        for: structure.structureType.typeID
                      ),
                      let group = Formats.IconMap.Group(rawValue: groupRaw),
                      let info = Simulation.StructureInfo.lookup(structure.structureType.typeID) {
                // Paint the fully-built footprint from the iconGroup's
                // tail tiles. Construction phases use the earlier tiles;
                // here we always pick the last `w × h` for "finished".
                let tiles = iconMap.tileIds(in: group)
                let (w, h) = info.layout.dimensions
                let needed = w * h
                if tiles.count >= needed {
                    let start = tiles.count - needed
                    for dy in 0..<h {
                        for dx in 0..<w {
                            let tx = Int(tile.x) + dx
                            let ty = Int(tile.y) + dy
                            guard tx < Map.width, ty < Map.height else { continue }
                            let cellIdx = ty * Map.width + tx
                            map.cells[cellIdx].groundTileID = tiles[start + dy * w + dx]
                            map.cells[cellIdx].hasStructure = true
                        }
                    }
                } else {
                    map.cells[index].hasStructure = true
                }
            } else {
                map.cells[index].hasStructure = true
            }
        }

        self.map = map
    }

    // MARK: - Queries

    public func units(at position: PackedPosition) -> [Scenario.UnitSpawn] {
        scenario.units.filter { $0.position == position }
    }

    public func structure(at position: PackedPosition) -> Scenario.StructureSpawn? {
        scenario.structures.first(where: { $0.position == position })
    }

    /// True if a cell holds a structure, a generated wall, or is out of bounds.
    public func isBlocked(at position: PackedPosition) -> Bool {
        let tile = position.tile
        guard tile.x < Map.width, tile.y < Map.height else { return true }
        let cell = map[Int(tile.x), Int(tile.y)]
        if cell.hasStructure { return true }
        // A wall tile is blocked; OpenDUNE flags this per `LandscapeType.wall`.
        let landscape = resolver.landscapeType(
            groundTileID: cell.groundTileID,
            overlayTileID: cell.overlayTileID,
            hasStructure: cell.hasStructure
        )
        return landscape == .wall || landscape == .structure
    }
}
