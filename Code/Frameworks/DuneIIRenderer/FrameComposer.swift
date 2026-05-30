import DuneIIContracts

/// An indexed (palette) sprite frame: row-major 8-bit pixels and its dimensions. Index 0 is transparent
/// for unit/effect sprites. The same shape as a decoded `SHP`/`ICN` frame, decoupled from the format.
public struct SpriteFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// The assets the `FrameComposer` needs, so compositing stays pure and asset-loading stays app-side.
/// Implementations resolve a global unit index via `GlobalSprite` + their own SHP/ICN stores.
public protocol WorldSpriteSource {
    /// The square pixel size of one terrain tile (16 for `ICON.ICN`). Also the world→image scale: one
    /// tile is 256 sub-tile units wide, so `imagePx = worldPos * terrainTileSize / 256`.
    var terrainTileSize: Int { get }
    /// The `terrainTileSize`² indexed pixels of ground tile `id` (an `ICON.ICN` tile), or `nil`.
    func terrainTile(_ id: Int) -> [UInt8]?
    /// The indexed frame for a global unit/effect sprite index (a UNITS-sheet frame), or `nil`.
    func unitFrame(globalIndex: Int) -> SpriteFrame?
}

/// One resolved drawable: an indexed sprite frame placed in **image space** (y-down, top-left origin),
/// with an optional house recolour and a z order. The leaf colorizes (palette + `HouseRemap`) and lays
/// it out; the composer chose the frame, position, flip, and tint.
public struct ComposedSprite: Equatable, Sendable {
    public let frame: SpriteFrame
    /// Image-space centre in base pixels (tile size 16).
    public let centerX: Int
    public let centerY: Int
    public let flipped: Bool
    /// The house to recolour to, or `nil` for house-neutral sprites (explosions, smoke).
    public let house: House?
    public let z: Int

    public init(frame: SpriteFrame, centerX: Int, centerY: Int, flipped: Bool, house: House?, z: Int) {
        self.frame = frame
        self.centerX = centerX
        self.centerY = centerY
        self.flipped = flipped
        self.house = house
        self.z = z
    }
}

/// Pure compositing of a `FrameInfo` into renderable pixels. The terrain ground layer becomes one
/// indexed buffer (buildings are baked into the ground tiles); units + effects become `ComposedSprite`s.
/// No CoreGraphics, no palette — fully headless-testable. See `Documentation/Architecture/Renderer.md`.
public enum FrameComposer {
    /// Image-space draw orders (smaller = drawn first / further back).
    public enum ZOrder {
        public static let terrain = 0
        public static let body = 1
        public static let turret = 2
        public static let effect = 3
    }

    /// The full-map ground layer as a `side × side` indexed buffer (`side = terrainTileSize · mapWidth`,
    /// row-major, y-down). Out-of-range tile ids are left as index 0.
    public static func terrainBuffer(_ frame: FrameInfo, source: WorldSpriteSource) -> [UInt8] {
        let ts = source.terrainTileSize
        let side = ts * frame.mapWidth
        var buffer = [UInt8](repeating: 0, count: side * (ts * frame.mapHeight))
        for ty in 0 ..< frame.mapHeight {
            for tx in 0 ..< frame.mapWidth {
                let tile = frame.tiles[ty * frame.mapWidth + tx]
                guard let pixels = source.terrainTile(tile.groundSpriteIndex), pixels.count >= ts * ts
                else { continue }
                let ox = tx * ts, oy = ty * ts
                for py in 0 ..< ts {
                    let row = (oy + py) * side + ox
                    for px in 0 ..< ts { buffer[row + px] = pixels[py * ts + px] }
                }
            }
        }
        return buffer
    }

    /// The unit (body + turret) and effect (explosion / smoke) sprites, resolved + placed in image space.
    public static func sprites(_ frame: FrameInfo, source: WorldSpriteSource) -> [ComposedSprite] {
        let ts = source.terrainTileSize
        var result: [ComposedSprite] = []

        func imageX(_ worldX: Int) -> Int { worldX * ts / 256 }
        func imageY(_ worldY: Int) -> Int { worldY * ts / 256 }

        for u in frame.units {
            let house = House(rawValue: u.house.rawValue)
            let cx = imageX(u.positionX), cy = imageY(u.positionY)
            if let body = source.unitFrame(globalIndex: u.body.spriteIndex) {
                result.append(ComposedSprite(frame: body, centerX: cx + u.body.offsetX,
                                             centerY: cy + u.body.offsetY, flipped: u.body.flipped,
                                             house: house, z: ZOrder.body))
            }
            if let turret = u.turret, let frame = source.unitFrame(globalIndex: turret.spriteIndex) {
                result.append(ComposedSprite(frame: frame, centerX: cx + turret.offsetX,
                                             centerY: cy + turret.offsetY, flipped: turret.flipped,
                                             house: house, z: ZOrder.turret))
            }
        }

        for e in frame.effects {
            guard let f = source.unitFrame(globalIndex: e.sprite.spriteIndex) else { continue }
            result.append(ComposedSprite(frame: f, centerX: imageX(e.positionX) + e.sprite.offsetX,
                                         centerY: imageY(e.positionY) + e.sprite.offsetY,
                                         flipped: e.sprite.flipped, house: nil, z: ZOrder.effect))
        }
        return result
    }
}
