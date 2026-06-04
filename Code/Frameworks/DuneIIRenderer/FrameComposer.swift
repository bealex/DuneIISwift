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
    /// The source global sprite index — a stable identity for caching the colorized texture by
    /// appearance `(spriteIndex, house)` (the flip is a node transform, not part of the texture).
    public let spriteIndex: Int
    public let frame: SpriteFrame
    /// Image-space centre in base pixels (tile size 16).
    public let centerX: Int
    public let centerY: Int
    public let flipped: Bool  // horizontal mirror
    public let flippedV: Bool  // vertical mirror (air units' southern facings)
    /// The house to recolour to, or `nil` for house-neutral sprites (explosions, smoke).
    public let house: House?
    public let z: Int

    public init(
        spriteIndex: Int,
        frame: SpriteFrame,
        centerX: Int,
        centerY: Int,
        flipped: Bool,
        flippedV: Bool = false,
        house: House?,
        z: Int
    ) {
        self.spriteIndex = spriteIndex
        self.frame = frame
        self.centerX = centerX
        self.centerY = centerY
        self.flipped = flipped
        self.flippedV = flippedV
        self.house = house
        self.z = z
    }
}

/// Pure compositing of a `FrameInfo` into renderable pixels. The terrain ground layer becomes one
/// indexed buffer (buildings are baked into the ground tiles); units + effects become `ComposedSprite`s.
/// No CoreGraphics, no palette — fully headless-testable. See `Documentation/Architecture/Renderer.md`.
public enum FrameComposer {
    /// Image-space draw orders (smaller = drawn first / further back). Mirrors `viewport.c`'s draw passes:
    /// terrain → ground units (body, harvest overlay, turret) → explosions/smoke → air units, drawn last
    /// on top of everything.
    public enum ZOrder {
        public static let terrain = 0
        public static let body = 1
        public static let overlay = 2  // harvester "harvesting" layer, above the body
        public static let turret = 3
        public static let effect = 4  // explosions + smoke, above ground units
        public static let airBody = 5  // winger units (carryall/ornithopter/frigate/missiles) on top
        public static let airTurret = 6
    }

    /// The palette index OpenDUNE fills a fully-veiled tile with (`GUI_DrawFilledRectangle(..., 12)`,
    /// `viewport.c:390`).
    public static let fogColourIndex: UInt8 = 12

    /// The palette index for a tile outside the scenario's playable rectangle (`FrameInfo.mapArea`) — the
    /// unused map border. Same colour-12 black as fog; drawn unconditionally (independent of `showFog`).
    public static let borderColourIndex: UInt8 = 12

    /// The composed `terrainTileSize²` indexed pixels for one map cell: the ground tile (house-recoloured
    /// for an owned/structure tile; identity for terrain / Harkonnen), then any **non-veil overlay** (a
    /// wall) drawn on top **with index-0 transparency** so the ground shows through the overlay's
    /// transparent pixels (`GFX_DrawTile`, `gfx.c:210` — overlay/wall tiles skip colour 0). When the
    /// overlay is the **veil** and `showFog` is on, the cell is a solid black fog square; with `showFog`
    /// off a veiled cell shows its ground (the verification "debug scenario" view). Returns `nil` if the
    /// ground tile id is unknown.
    public static func cell(
        _ tile: FrameInfo.Tile,
        veiledTileIndex: Int,
        showFog: Bool,
        source: WorldSpriteSource
    ) -> [UInt8]? {
        let ts = source.terrainTileSize
        // Fully-veiled cell: a black square (OpenDUNE never draws the veil sprite, it fills colour 12).
        if showFog && tile.overlaySpriteIndex != 0 && tile.overlaySpriteIndex == veiledTileIndex {
            return [UInt8](repeating: fogColourIndex, count: ts * ts)
        }
        guard let ground = source.terrainTile(tile.groundSpriteIndex), ground.count >= ts * ts else { return nil }

        // House-recolour owned (structure / house-coloured wall) tiles; terrain / Harkonnen is identity.
        let house = tile.houseID == 0 ? nil : House(rawValue: Int(tile.houseID))

        func recolour(_ p: UInt8) -> UInt8 { house.map { HouseRemap.tile(p, house: $0) } ?? p }

        var out = house == nil ? ground : ground.map(recolour)
        // Composite a non-veil overlay (a wall) over the ground: GFX_DrawTile blits the overlay tile with
        // colour-0 transparency, so only its non-zero pixels overwrite the ground (the rest shows through).
        let overlayId = tile.overlaySpriteIndex
        if overlayId != 0, overlayId != veiledTileIndex,
                let overlay = source.terrainTile(overlayId), overlay.count >= ts * ts {
            for i in 0 ..< (ts * ts) where overlay[i] != 0 { out[i] = recolour(overlay[i]) }
        }
        // A partial fog edge (a revealed tile bordering the unknown) — only with fog on. House-neutral
        // (fog colours aren't in the house-remap block); same colour-0 transparency as any overlay.
        if showFog, tile.fogEdgeSpriteIndex != 0,
                let fog = source.terrainTile(tile.fogEdgeSpriteIndex), fog.count >= ts * ts {
            for i in 0 ..< (ts * ts) where fog[i] != 0 { out[i] = fog[i] }
        }
        return out
    }

    /// The full-map ground layer as a `side × side` indexed buffer (`side = terrainTileSize · mapWidth`,
    /// row-major, y-down). Composes ground + overlay + fog per cell (see `cell`). Out-of-range / unknown
    /// tile ids are left as index 0. `showFog` blacks out veiled cells; off (default) shows the landscape.
    public static func terrainBuffer(_ frame: FrameInfo, source: WorldSpriteSource, showFog: Bool = false) -> [UInt8] {
        let ts = source.terrainTileSize
        let side = ts * frame.mapWidth
        var buffer = [UInt8](repeating: 0, count: side * (ts * frame.mapHeight))
        let border = [UInt8](repeating: borderColourIndex, count: ts * ts)
        for ty in 0 ..< frame.mapHeight {
            for tx in 0 ..< frame.mapWidth {
                // Outside the scenario's playable rectangle: the unused border draws solid black, never the
                // landscape underneath (independent of fog). Inside: compose the cell normally.
                let pixels: [UInt8]
                if !frame.mapArea.contains(tileX: tx, tileY: ty) {
                    pixels = border
                } else if let p = cell(
                    frame.tiles[ty * frame.mapWidth + tx],
                    veiledTileIndex: frame.veiledTileIndex,
                    showFog: showFog,
                    source: source
                ) {
                    pixels = p
                } else {
                    continue
                }
                let ox = tx * ts, oy = ty * ts
                for py in 0 ..< ts {
                    let row = (oy + py) * side + ox
                    for px in 0 ..< ts { buffer[row + px] = pixels[py * ts + px] }
                }
            }
        }
        return buffer
    }

    /// Whether the cell at a world position is hidden under fog — `showFog` on **and** the underlying tile
    /// is still veiled (`!isUnveiled`). Mirrors `viewport.c`: every entity pass (units, explosions, smoke,
    /// sandworms) does `if (!g_map[curPos].isUnveiled && !g_debugScenario) continue` — so an enemy sitting
    /// in the fog isn't drawn at all (only revealed tiles black-fill via the terrain pass). Off-map / out
    /// of range is treated as visible (no spurious hide).
    public static func isHiddenByFog(_ frame: FrameInfo, worldX: Int, worldY: Int, showFog: Bool) -> Bool {
        guard showFog else { return false }

        let tx = worldX / 256, ty = worldY / 256
        guard (0 ..< frame.mapWidth).contains(tx), (0 ..< frame.mapHeight).contains(ty) else { return false }

        return !frame.tiles[ty * frame.mapWidth + tx].isUnveiled
    }

    /// Whether the world position falls outside the scenario's playable rectangle (`FrameInfo.mapArea`) — its
    /// sprite belongs to the unused border and must not be drawn (the rendering twin of `Map_IsValidPosition`).
    public static func isOutsideMapArea(_ frame: FrameInfo, worldX: Int, worldY: Int) -> Bool {
        !frame.mapArea.contains(tileX: worldX / 256, tileY: worldY / 256)
    }

    /// The unit (body + turret) and effect (explosion / smoke) sprites, resolved + placed in image space.
    /// When `showFog` is on, units/effects on a still-veiled tile are omitted (`viewport.c` masks each
    /// entity pass by the tile's `isUnveiled` — enemies in the fog aren't drawn). A unit/effect outside the
    /// playable rectangle (`mapArea`) is likewise dropped so nothing paints over the black border.
    public static func sprites(_ frame: FrameInfo, source: WorldSpriteSource, showFog: Bool = false) -> [ComposedSprite]
    {
        let ts = source.terrainTileSize
        var result: [ComposedSprite] = []

        func imageX(_ worldX: Int) -> Int { worldX * ts / 256 }

        func imageY(_ worldY: Int) -> Int { worldY * ts / 256 }

        for u in frame.units {
            if isOutsideMapArea(frame, worldX: u.positionX, worldY: u.positionY) { continue }
            if isHiddenByFog(frame, worldX: u.positionX, worldY: u.positionY, showFog: showFog) { continue }
            let house = House(rawValue: u.house.rawValue)
            let cx = imageX(u.positionX), cy = imageY(u.positionY)
            // Air units (wingers) draw on top of ground units + explosions (a separate `viewport.c` pass).
            let bodyZ = u.isAirUnit ? ZOrder.airBody : ZOrder.body
            let turretZ = u.isAirUnit ? ZOrder.airTurret : ZOrder.turret
            if let body = source.unitFrame(globalIndex: u.body.spriteIndex) {
                result.append(
                    ComposedSprite(
                        spriteIndex: u.body.spriteIndex,
                        frame: body,
                        centerX: cx + u.body.offsetX,
                        centerY: cy + u.body.offsetY,
                        flipped: u.body.flipped,
                        flippedV: u.body.flippedV,
                        house: house,
                        z: bodyZ
                    )
                )
            }
            // The harvesting overlay is drawn without the house palette (`viewport.c:546` — its
            // `GetSprite_HousePalette` call is commented out), so it is house-neutral.
            if let overlay = u.overlay, let frame = source.unitFrame(globalIndex: overlay.spriteIndex) {
                result.append(
                    ComposedSprite(
                        spriteIndex: overlay.spriteIndex,
                        frame: frame,
                        centerX: cx + overlay.offsetX,
                        centerY: cy + overlay.offsetY,
                        flipped: overlay.flipped,
                        flippedV: overlay.flippedV,
                        house: nil,
                        z: ZOrder.overlay
                    )
                )
            }
            if let turret = u.turret, let frame = source.unitFrame(globalIndex: turret.spriteIndex) {
                result.append(
                    ComposedSprite(
                        spriteIndex: turret.spriteIndex,
                        frame: frame,
                        centerX: cx + turret.offsetX,
                        centerY: cy + turret.offsetY,
                        flipped: turret.flipped,
                        flippedV: turret.flippedV,
                        house: house,
                        z: turretZ
                    )
                )
            }
        }

        for e in frame.effects {
            if isOutsideMapArea(frame, worldX: e.positionX, worldY: e.positionY) { continue }
            if isHiddenByFog(frame, worldX: e.positionX, worldY: e.positionY, showFog: showFog) { continue }
            guard let f = source.unitFrame(globalIndex: e.sprite.spriteIndex) else { continue }

            result.append(
                ComposedSprite(
                    spriteIndex: e.sprite.spriteIndex,
                    frame: f,
                    centerX: imageX(e.positionX) + e.sprite.offsetX,
                    centerY: imageY(e.positionY) + e.sprite.offsetY,
                    flipped: e.sprite.flipped,
                    house: nil,
                    z: ZOrder.effect
                )
            )
        }
        return result
    }
}
