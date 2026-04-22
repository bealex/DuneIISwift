import Foundation
import DuneIICore

/// Pure-Foundation minimap pixel renderer. Produces a 64×64 RGBA buffer
/// from the live tile grid + unit / structure pools; the scene wraps it
/// as an `SKTexture` every tick.
///
/// Design: `Documentation/Algorithms/Minimap.md`.
public enum Minimap {
    /// Edge length of the minimap in pixels. Matches the 64×64 map so
    /// every map tile gets exactly one pixel; the scene upscales with
    /// nearest-neighbour filtering.
    public static let size: Int = 64

    public struct ColorRGBA: Sendable, Equatable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public let a: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 0xFF) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    /// 16384-byte `premultipliedLast` RGBA buffer: row-major, top-left
    /// origin, one pixel per map tile. Terrain painted first, then
    /// units, then structure footprints.
    public static func render(
        tileGrid: [Simulation.WorldSnapshot.Tile],
        landscapeAt: (Simulation.WorldSnapshot.Tile) -> LandscapeType,
        units: Simulation.UnitPool,
        structures: Simulation.StructurePool,
        houseColor: (UInt8) -> ColorRGBA
    ) -> [UInt8] {
        let n = size * size
        var buffer = [UInt8](repeating: 0, count: n * 4)

        // Terrain pass. Guard on tileGrid.count since callers can pass
        // shorter buffers in degraded states (e.g. pre-load ticks).
        for cell in 0..<min(n, tileGrid.count) {
            let color = terrainColor(landscapeAt(tileGrid[cell]))
            let off = cell * 4
            buffer[off    ] = color.r
            buffer[off + 1] = color.g
            buffer[off + 2] = color.b
            buffer[off + 3] = color.a
        }
        // Fill any uncovered tail with opaque black so the texture
        // upload still succeeds.
        if tileGrid.count < n {
            for cell in tileGrid.count..<n {
                buffer[cell * 4 + 3] = 0xFF
            }
        }

        // Unit pass.
        for idx in units.findArray {
            let u = units.slots[idx]
            guard u.isUsed else { continue }
            if Simulation.Scheduler.isProjectileType(u.type) { continue }
            let tx = Int(u.positionX) / 256
            let ty = Int(u.positionY) / 256
            guard (0..<size).contains(tx), (0..<size).contains(ty) else { continue }
            writePixel(&buffer, x: tx, y: ty, color: houseColor(u.houseID))
        }

        // Structure footprint pass — runs after units so large
        // footprints don't get "holes" from an overlapping unit dot.
        for idx in structures.findArray {
            let s = structures.slots[idx]
            guard s.isUsed, s.isAllocated else { continue }
            // Slabs and walls read as terrain; don't paint over them.
            if s.type == 0 || s.type == 1 || s.type == 14 { continue }
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            let color = houseColor(s.houseID)
            for (fx, fy) in footprint {
                guard (0..<size).contains(fx), (0..<size).contains(fy) else { continue }
                writePixel(&buffer, x: fx, y: fy, color: color)
            }
        }

        return buffer
    }

    /// Readable colour per `LandscapeType`. Values chosen for sidebar
    /// legibility at 120×120 pt nearest-neighbour upscale, not for
    /// OpenDUNE radar-palette parity.
    public static func terrainColor(_ type: LandscapeType) -> ColorRGBA {
        switch type {
        case .normalSand, .partialDune, .entirelyDune:
            return ColorRGBA(r: 0xC8, g: 0xA6, b: 0x64)
        case .partialRock, .entirelyRock, .mostlyRock:
            return ColorRGBA(r: 0x80, g: 0x70, b: 0x56)
        case .partialMountain, .entirelyMountain:
            return ColorRGBA(r: 0x5C, g: 0x4A, b: 0x36)
        case .spice:
            return ColorRGBA(r: 0xE8, g: 0x90, b: 0x24)
        case .thickSpice:
            return ColorRGBA(r: 0xD4, g: 0x68, b: 0x18)
        case .concreteSlab:
            return ColorRGBA(r: 0xA0, g: 0xA0, b: 0xA0)
        case .wall, .destroyedWall:
            return ColorRGBA(r: 0x70, g: 0x70, b: 0x70)
        case .structure:
            return ColorRGBA(r: 0x55, g: 0x55, b: 0x55)
        case .bloomField:
            return ColorRGBA(r: 0xB8, g: 0x90, b: 0x58)
        }
    }

    private static func writePixel(
        _ buffer: inout [UInt8], x: Int, y: Int, color: ColorRGBA
    ) {
        let off = (y * size + x) * 4
        buffer[off    ] = color.r
        buffer[off + 1] = color.g
        buffer[off + 2] = color.b
        buffer[off + 3] = color.a
    }
}
