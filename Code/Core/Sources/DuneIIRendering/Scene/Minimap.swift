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

    /// A tile-space rectangle — used for both "what part of the 64×64
    /// tile grid the minimap samples" and "what part of it is
    /// currently visible through the camera". All coords in tiles.
    public struct Rect: Sendable, Equatable {
        public var originX: Int
        public var originY: Int
        public var width: Int
        public var height: Int
        public init(originX: Int, originY: Int, width: Int, height: Int) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
        }
        public static let fullMap = Rect(originX: 0, originY: 0, width: 64, height: 64)
    }

    /// 16384-byte `premultipliedLast` RGBA buffer: row-major, top-left
    /// origin. `rect` is the tile region sampled — the output always
    /// has `size × size` pixels, so each output pixel represents
    /// `rect.width / size` tiles in x and `rect.height / size` in y.
    /// `viewport` (optional) draws a white outline showing the camera's
    /// currently-visible tile range on top of the minimap.
    public static func render(
        tileGrid: [Simulation.WorldSnapshot.Tile],
        landscapeAt: (Simulation.WorldSnapshot.Tile) -> LandscapeType,
        units: Simulation.UnitPool,
        structures: Simulation.StructurePool,
        houseColor: (UInt8) -> ColorRGBA,
        rect: Rect = .fullMap,
        viewport: Rect? = nil
    ) -> [UInt8] {
        let n = size * size
        var buffer = [UInt8](repeating: 0, count: n * 4)
        // Opaque-black default for any output pixel we fail to cover.
        for i in 0..<n { buffer[i * 4 + 3] = 0xFF }

        let rectW = max(rect.width, 1)
        let rectH = max(rect.height, 1)
        // Terrain pass. Each output pixel samples the underlying tile
        // at the proportional position within `rect`.
        for py in 0..<size {
            for px in 0..<size {
                let tx = rect.originX + (px * rectW) / size
                let ty = rect.originY + (py * rectH) / size
                guard (0..<64).contains(tx), (0..<64).contains(ty) else { continue }
                let cell = ty * 64 + tx
                guard cell < tileGrid.count else { continue }
                let color = terrainColor(landscapeAt(tileGrid[cell]))
                writePixel(&buffer, x: px, y: py, color: color)
            }
        }

        // Convert a sim-tile coord to the output pixel coord under
        // the current crop.
        func pixelFor(tx: Int, ty: Int) -> (x: Int, y: Int)? {
            let px = ((tx - rect.originX) * size) / rectW
            let py = ((ty - rect.originY) * size) / rectH
            guard (0..<size).contains(px), (0..<size).contains(py) else { return nil }
            return (px, py)
        }

        // Unit pass.
        for idx in units.findArray {
            let u = units.slots[idx]
            guard u.isUsed else { continue }
            if Simulation.Scheduler.isProjectileType(u.type) { continue }
            let tx = Int(u.positionX) / 256
            let ty = Int(u.positionY) / 256
            guard let p = pixelFor(tx: tx, ty: ty) else { continue }
            writePixel(&buffer, x: p.x, y: p.y, color: houseColor(u.houseID))
        }

        // Structure footprint pass.
        for idx in structures.findArray {
            let s = structures.slots[idx]
            guard s.isUsed, s.isAllocated else { continue }
            if s.type == 0 || s.type == 1 || s.type == 14 { continue }
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            let color = houseColor(s.houseID)
            for (fx, fy) in footprint {
                guard let p = pixelFor(tx: fx, ty: fy) else { continue }
                writePixel(&buffer, x: p.x, y: p.y, color: color)
            }
        }

        // Viewport overlay — white rectangle on the minimap showing
        // which tile range the camera currently sees. Drawn last so
        // it sits on top of terrain + unit dots.
        if let viewport {
            let v0x = ((viewport.originX - rect.originX) * size) / rectW
            let v0y = ((viewport.originY - rect.originY) * size) / rectH
            let v1x = (((viewport.originX + viewport.width) - rect.originX) * size) / rectW
            let v1y = (((viewport.originY + viewport.height) - rect.originY) * size) / rectH
            let xMin = max(0, min(size - 1, v0x))
            let yMin = max(0, min(size - 1, v0y))
            let xMax = max(0, min(size - 1, v1x - 1))
            let yMax = max(0, min(size - 1, v1y - 1))
            let white = ColorRGBA(r: 0xFF, g: 0xFF, b: 0xFF)
            if xMin <= xMax, yMin <= yMax {
                for x in xMin...xMax {
                    writePixel(&buffer, x: x, y: yMin, color: white)
                    writePixel(&buffer, x: x, y: yMax, color: white)
                }
                for y in yMin...yMax {
                    writePixel(&buffer, x: xMin, y: y, color: white)
                    writePixel(&buffer, x: xMax, y: y, color: white)
                }
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
