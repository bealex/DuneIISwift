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
            id == 0 ? nil : [UInt8](repeating: UInt8(truncatingIfNeeded: id), count: 16)
        }
        func unitFrame(globalIndex: Int) -> SpriteFrame? {
            globalIndex < 111 ? nil
                : SpriteFrame(width: 2, height: 2, pixels: [UInt8](repeating: UInt8(truncatingIfNeeded: 100 + globalIndex), count: 4))
        }
    }

    private func emptyFrame(units: [FrameInfo.Unit] = [], effects: [FrameInfo.Effect] = [],
                            tiles: [FrameInfo.Tile]? = nil, w: Int = 3, h: Int = 2) -> FrameInfo {
        let blank = FrameInfo.Tile(groundSpriteIndex: 0, overlaySpriteIndex: 0, isUnveiled: false)
        return FrameInfo(tick: 0, mapWidth: w, mapHeight: h,
                         tiles: tiles ?? [FrameInfo.Tile](repeating: blank, count: w * h),
                         units: units, structures: [], effects: effects, houses: [],
                         viewportX: 0, viewportY: 0)
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
        let blank = FrameInfo.Tile(groundSpriteIndex: 0, overlaySpriteIndex: 0, isUnveiled: false)
        var tiles = [FrameInfo.Tile](repeating: blank, count: 6)
        tiles[0 * 3 + 1] = FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 0, isUnveiled: true)
        tiles[1 * 3 + 2] = FrameInfo.Tile(groundSpriteIndex: 9, overlaySpriteIndex: 0, isUnveiled: true)
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
        #expect(body.frame.pixels.first == UInt8(100 + 113))

        let turret = try #require(sprites.first { $0.z == FrameComposer.ZOrder.turret })
        #expect(turret.centerX == 7 && turret.centerY == 6)         // (6+1, 8-2)
        #expect(turret.house == .atreides)
        #expect(turret.z > body.z)                                   // turret drawn over body
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
