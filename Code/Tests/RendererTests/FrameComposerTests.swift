import Testing
import DuneIIContracts
@testable import DuneIIRenderer

/// The FrameInfo-consumer core of the renderer: `GlobalSprite` (the load-order mapping), `NullRenderer`
/// (records the last frame), and `FrameComposer` (pure terrain + sprite compositing from a `FrameInfo`).
/// See `Documentation/Architecture/Renderer.md`.
@Suite("Frame composer")
struct FrameComposerTests {
    /// A synthetic asset source: terrain tiles are 4×4 (so positions are easy to read) filled with a
    /// constant = the tile id; a unit frame is a 2×2 filled with `100 + globalIndex`.
    private struct FakeSource: WorldSpriteSource {
        var terrainTileSize: Int { 4 }
        func terrainTile(_ id: Int) -> [UInt8]? {
            if id == 0 { return nil }
            // Tile 7 is a "wall": its top half is opaque (id 7), its bottom half transparent (index 0),
            // so the overlay-composite test can see the ground show through the transparent pixels.
            if id == 7 { return [UInt8](repeating: 7, count: 8) + [UInt8](repeating: 0, count: 8) }
            return [UInt8](repeating: UInt8(truncatingIfNeeded: id), count: 16)
        }
        func unitFrame(globalIndex: Int) -> SpriteFrame? {
            globalIndex < 111 ? nil
                : SpriteFrame(width: 2, height: 2, pixels: [UInt8](repeating: UInt8(truncatingIfNeeded: 100 + globalIndex), count: 4))
        }
    }

    private func emptyFrame(units: [FrameInfo.Unit] = [], effects: [FrameInfo.Effect] = [],
                            tiles: [FrameInfo.Tile]? = nil, w: Int = 3, h: Int = 2) -> FrameInfo {
        let blank = FrameInfo.Tile(groundSpriteIndex: 0, overlaySpriteIndex: 0, houseID: 0, isUnveiled: false)
        return FrameInfo(tick: 0, mapWidth: w, mapHeight: h,
                         tiles: tiles ?? [FrameInfo.Tile](repeating: blank, count: w * h),
                         units: units, structures: [], effects: effects, houses: [],
                         viewportX: 0, viewportY: 0)
    }

    @Test("DecodedSpriteSource resolves through GlobalSprite; empty source is safely nil")
    func decodedSpriteSource() {
        // No assets: a sprite-only stub. terrainTileSize falls back to 16; every lookup is nil rather than
        // a crash — the headless/test path can construct a source incrementally.
        let empty = DecodedSpriteSource(tileSet: nil, sheets: [:])
        #expect(empty.terrainTileSize == 16)
        #expect(empty.terrainTile(0) == nil)
        #expect(empty.terrainTile(238) == nil)
        // A global index with no backing sheet resolves to nil (GlobalSprite maps it, the sheet is absent).
        #expect(empty.unitFrame(globalIndex: 238) == nil)
        #expect(empty.unitFrame(globalIndex: 0) == nil)        // below the unit base → GlobalSprite nil
    }

    @Test("GlobalSprite maps a global index to its sheet + frame via the Sprites_Init bases")
    func globalSprite() {
        #expect(GlobalSprite.unit(110) == nil)                       // below the unit base
        #expect(GlobalSprite.unit(111)?.sheet == .units2)            // UNITS2 base
        #expect(GlobalSprite.unit(120)?.frame == 9)
        #expect(GlobalSprite.unit(151)?.sheet == .units1)            // UNITS1 base
        #expect(GlobalSprite.unit(238)?.sheet == .units)             // UNITS base
        #expect(GlobalSprite.unit(238)?.frame == 0)
        #expect(UnitSpriteSheet.units.fileName == "UNITS.SHP")
    }

    @Test("NullRenderer records the last frame and draws nothing")
    func nullRenderer() {
        var r = NullRenderer()
        #expect(r.lastFrame == nil)
        r.render(emptyFrame())
        #expect(r.lastFrame?.mapWidth == 3)
    }

    @Test("terrain buffer composites ground tiles into a side×side indexed image")
    func terrainBuffer() {
        // A 3×2 map; tile (1,0) = id 5, tile (2,1) = id 9, rest 0 (→ left as index 0).
        let blank = FrameInfo.Tile(groundSpriteIndex: 0, overlaySpriteIndex: 0, houseID: 0, isUnveiled: false)
        var tiles = [FrameInfo.Tile](repeating: blank, count: 6)
        tiles[0 * 3 + 1] = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 0, houseID: 0, isUnveiled: true)
        tiles[1 * 3 + 2] = FrameInfo.Tile(groundSpriteIndex: 9, overlaySpriteIndex: 0, houseID: 0, isUnveiled: true)
        let frame = emptyFrame(tiles: tiles)

        let buf = FrameComposer.terrainBuffer(frame, source: FakeSource())
        let side = 4 * 3   // terrainTileSize · mapWidth
        #expect(buf.count == side * (4 * 2))
        // Tile (1,0) occupies image cols 4..7, rows 0..3 → all 5.
        #expect(buf[0 * side + 4] == 5 && buf[3 * side + 7] == 5)
        // Tile (2,1) occupies cols 8..11, rows 4..7 → all 9.
        #expect(buf[4 * side + 8] == 9 && buf[7 * side + 11] == 9)
        // An untouched tile stays 0.
        #expect(buf[0] == 0)
    }

    @Test("cell composes ground, overlay (walls), and fog")
    func cellComposition() throws {
        let src = FakeSource()
        // No overlay → ground tile id 5 (terrain, no remap).
        let ground = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 0, houseID: 0, isUnveiled: true)
        #expect(FrameComposer.cell(ground, veiledTileIndex: 99, showFog: false, source: src)?.allSatisfy { $0 == 5 } == true)

        // A non-veil overlay (id 7, a wall) composites over the ground with index-0 transparency: the
        // wall's opaque top half overwrites with 7, its transparent bottom half shows the ground (5).
        let walled = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 7, houseID: 0, isUnveiled: true)
        let composed = try #require(FrameComposer.cell(walled, veiledTileIndex: 99, showFog: false, source: src))
        #expect(composed.prefix(8).allSatisfy { $0 == 7 })
        #expect(composed.suffix(8).allSatisfy { $0 == 5 })

        // A veiled cell (overlay == veil id) → black (index 12) with fog on, ground with fog off.
        let veiled = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 99, houseID: 0, isUnveiled: false)
        #expect(FrameComposer.cell(veiled, veiledTileIndex: 99, showFog: true, source: src)?
            .allSatisfy { $0 == FrameComposer.fogColourIndex } == true)
        #expect(FrameComposer.cell(veiled, veiledTileIndex: 99, showFog: false, source: src)?.allSatisfy { $0 == 5 } == true)

        // An owned overlay is house-remapped (tile 0x91 → +16 for Atreides).
        let ownedWall = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 0x91, houseID: 1, isUnveiled: true)
        #expect(FrameComposer.cell(ownedWall, veiledTileIndex: 99, showFog: false, source: src)?.first == 161)
    }

    @Test("terrainBuffer blacks out veiled cells only when fog is on")
    func terrainBufferFog() {
        let blank = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 99, houseID: 0, isUnveiled: false)
        let frame = FrameInfo(tick: 0, mapWidth: 3, mapHeight: 2,
                              tiles: [FrameInfo.Tile](repeating: blank, count: 6), units: [], structures: [],
                              effects: [], houses: [], viewportX: 0, viewportY: 0, veiledTileIndex: 99)
        // Fog off → ground (5) everywhere.
        #expect(FrameComposer.terrainBuffer(frame, source: FakeSource(), showFog: false).allSatisfy { $0 == 5 })
        // Fog on → black (12) everywhere.
        #expect(FrameComposer.terrainBuffer(frame, source: FakeSource(), showFog: true).allSatisfy { $0 == FrameComposer.fogColourIndex })
    }

    @Test("terrain house-remaps an owned (structure) tile; Harkonnen/terrain is identity")
    func terrainHouseRemap() {
        // Tile id 0x91 (145) → pixels all 145 (in the 0x90 house-colour block). HouseRemap.tile for
        // Atreides (1) shifts the 0x90 block by 1<<4 = 16 → 161; Harkonnen (0) leaves it 145.
        let owned = FrameInfo.Tile(groundSpriteIndex: 0x91, overlaySpriteIndex: 0, houseID: 1, isUnveiled: true)
        let neutral = FrameInfo.Tile(groundSpriteIndex: 0x91, overlaySpriteIndex: 0, houseID: 0, isUnveiled: true)
        let blank = FrameInfo.Tile(groundSpriteIndex: 0, overlaySpriteIndex: 0, houseID: 0, isUnveiled: false)

        var tilesO = [FrameInfo.Tile](repeating: blank, count: 6); tilesO[0] = owned
        let bufO = FrameComposer.terrainBuffer(emptyFrame(tiles: tilesO), source: FakeSource())
        #expect(bufO[0] == 161)   // recoloured to Atreides

        var tilesN = [FrameInfo.Tile](repeating: blank, count: 6); tilesN[0] = neutral
        let bufN = FrameComposer.terrainBuffer(emptyFrame(tiles: tilesN), source: FakeSource())
        #expect(bufN[0] == 145)   // Harkonnen/terrain left as-is
    }

    @Test("unit body + turret resolve to placed, house-tinted, z-ordered sprites")
    func unitSprites() throws {
        // A tank at world (1.5 tiles, 2.0 tiles) → image (1.5·4, 2.0·4) = (6, 8); turret offset (1,-2).
        let unit = FrameInfo.Unit(
            id: 0, type: .tank, house: .atreides,
            positionX: 256 + 128, positionY: 512,
            body: SpriteLayer(spriteIndex: 113, flipped: true),
            turret: SpriteLayer(spriteIndex: 116, flipped: false, offsetX: 1, offsetY: -2),
            isSmoking: false, hitpoints: 50, hitpointsMax: 100)
        let sprites = FrameComposer.sprites(emptyFrame(units: [unit]), source: FakeSource())

        let body = try #require(sprites.first { $0.z == FrameComposer.ZOrder.body })
        #expect(body.centerX == 6 && body.centerY == 8)
        #expect(body.flipped)
        #expect(body.house == .atreides)
        #expect(body.spriteIndex == 113)                            // carried for texture caching
        #expect(body.frame.pixels.first == UInt8(100 + 113))

        let turret = try #require(sprites.first { $0.z == FrameComposer.ZOrder.turret })
        #expect(turret.spriteIndex == 116)
        #expect(turret.centerX == 7 && turret.centerY == 6)         // (6+1, 8-2)
        #expect(turret.house == .atreides)
        #expect(turret.z > body.z)                                   // turret drawn over body
    }

    @Test("mirror flips horizontally and/or vertically (the baked sprite flips)")
    func mirror() {
        // A 3×2 buffer: rows [1,2,3] and [4,5,6].
        let src: [UInt8] = [1, 2, 3, 4, 5, 6]
        // Horizontal: each row reversed.
        #expect(SpriteKitRenderer.mirror(src, width: 3, height: 2, horizontal: true, vertical: false) == [3, 2, 1, 6, 5, 4])
        // Vertical: row order reversed (air units' southern facings).
        #expect(SpriteKitRenderer.mirror(src, width: 3, height: 2, horizontal: false, vertical: true) == [4, 5, 6, 1, 2, 3])
        // Both.
        #expect(SpriteKitRenderer.mirror(src, width: 3, height: 2, horizontal: true, vertical: true) == [6, 5, 4, 3, 2, 1])
        // No flip is the identity; degenerate sizes are returned unchanged.
        #expect(SpriteKitRenderer.mirror(src, width: 3, height: 2, horizontal: false, vertical: false) == src)
        #expect(SpriteKitRenderer.mirror([9], width: 0, height: 0, horizontal: true, vertical: true) == [9])
    }

    @Test("air units (wingers) draw on top of ground units and effects")
    func airUnitZOrder() throws {
        let ground = FrameInfo.Unit(
            id: 0, type: .tank, house: .atreides, positionX: 256, positionY: 256,
            body: SpriteLayer(spriteIndex: 113), turret: nil, isSmoking: false,
            isAirUnit: false, hitpoints: 50, hitpointsMax: 100)
        let air = FrameInfo.Unit(
            id: 1, type: .carryall, house: .atreides, positionX: 256, positionY: 256,
            body: SpriteLayer(spriteIndex: 120), turret: nil, isSmoking: false,
            isAirUnit: true, hitpoints: 50, hitpointsMax: 100)
        let smoke = FrameInfo.Effect(positionX: 256, positionY: 256, sprite: SpriteLayer(spriteIndex: 182))
        let sprites = FrameComposer.sprites(emptyFrame(units: [ground, air], effects: [smoke]), source: FakeSource())

        let groundBody = try #require(sprites.first { $0.spriteIndex == 113 })
        let airBody = try #require(sprites.first { $0.spriteIndex == 120 })
        let fx = try #require(sprites.first { $0.spriteIndex == 182 })
        #expect(airBody.z == FrameComposer.ZOrder.airBody)
        #expect(airBody.z > fx.z)                    // air above explosions/smoke
        #expect(airBody.z > groundBody.z)            // air above ground units
        #expect(fx.z > groundBody.z)                 // explosions above ground units
    }

    @Test("harvester overlay composes house-neutral, between body and turret")
    func harvestOverlay() throws {
        let harvester = FrameInfo.Unit(
            id: 0, type: .harvester, house: .ordos, positionX: 256, positionY: 256,
            body: SpriteLayer(spriteIndex: 120),
            turret: nil, overlay: SpriteLayer(spriteIndex: 0xDF, offsetX: 0, offsetY: 7),
            isSmoking: false, isAirUnit: false, hitpoints: 50, hitpointsMax: 100)
        let sprites = FrameComposer.sprites(emptyFrame(units: [harvester]), source: FakeSource())
        let overlay = try #require(sprites.first { $0.z == FrameComposer.ZOrder.overlay })
        #expect(overlay.spriteIndex == 0xDF)
        #expect(overlay.house == nil)                                 // drawn without the house palette
        #expect(overlay.centerY == 4 + 7)                             // 1 tile = 4px, + the y offset
        #expect(overlay.z > FrameComposer.ZOrder.body && overlay.z < FrameComposer.ZOrder.turret)
    }

    @Test("effects compose house-neutral above units")
    func effectSprites() throws {
        let smoke = FrameInfo.Effect(positionX: 256, positionY: 256,
                                     sprite: SpriteLayer(spriteIndex: 182, offsetY: -14))
        let sprites = FrameComposer.sprites(emptyFrame(effects: [smoke]), source: FakeSource())
        let fx = try #require(sprites.first { $0.z == FrameComposer.ZOrder.effect })
        #expect(fx.house == nil)                                     // effects are not recoloured
        #expect(fx.centerX == 4 && fx.centerY == 4 - 14)            // 1 tile = 4px, minus the lift
        #expect(fx.z > FrameComposer.ZOrder.turret)
    }
}
