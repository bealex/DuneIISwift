import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("DuneIIRendering.UnitSpriteAtlas")
struct UnitSpriteAtlasTests {
    @Test("resolveFrame(unit) applies the octant offset for a DISPLAYMODE_UNIT tank")
    func resolveFrameUnit() {
        let tank = Simulation.UnitInfo.lookup(9)!
        // Orientation 0 = N → octant 0 → offset 0, no flip.
        let (id0, flip0) = UnitSpriteAtlas.resolveFrame(info: tank, orientation: 0)
        #expect(id0 == Int(tank.groundSpriteID))
        #expect(flip0 == false)
        // Orientation 64 = E → octant 2 → offset 2.
        let (id64, flip64) = UnitSpriteAtlas.resolveFrame(info: tank, orientation: 64)
        #expect(id64 == Int(tank.groundSpriteID) + 2)
        #expect(flip64 == false)
        // Orientation -64 (= 192) = W → octant 6 → reuse offset 2, flipped.
        let (id192, flip192) = UnitSpriteAtlas.resolveFrame(info: tank, orientation: -64)
        #expect(id192 == Int(tank.groundSpriteID) + 2)
        #expect(flip192 == true)
    }

    @Test("resolveFrame(sandworm) ignores orientation")
    func resolveFrameSlither() {
        let worm = Simulation.UnitInfo.lookup(25)!
        for o: Int8 in [0, 32, 64, -32, -96] {
            let (id, flip) = UnitSpriteAtlas.resolveFrame(info: worm, orientation: o)
            #expect(id == Int(worm.groundSpriteID))
            #expect(flip == false)
        }
    }

    @Test("resolveFrame(singleFrame) ignores orientation (bullet)")
    func resolveFrameSingleFrame() {
        let bullet = Simulation.UnitInfo.lookup(23)!
        let (id, flip) = UnitSpriteAtlas.resolveFrame(info: bullet, orientation: 100)
        #expect(id == Int(bullet.groundSpriteID))
        #expect(flip == false)
    }

    @Test("resolveFrame(infantry3) uses values_32C4 buckets + values_334A phase")
    func resolveFrameInfantry3() {
        let soldier = Simulation.UnitInfo.lookup(4)!
        // N (octant 0 → bucket 0). phase=0 → offset 0*3+0 = 0.
        let (n, nFlip) = UnitSpriteAtlas.resolveFrame(info: soldier, orientation: 0)
        #expect(n == Int(soldier.groundSpriteID))
        #expect(nFlip == false)
        // E (octant 2 → bucket 1). phase=0 → offset 1*3+0 = 3.
        let (e, eFlip) = UnitSpriteAtlas.resolveFrame(info: soldier, orientation: 64)
        #expect(e == Int(soldier.groundSpriteID) + 3)
        #expect(eFlip == false)
        // S (octant 4 → bucket 2). phase=0 → offset 2*3+0 = 6.
        let (s, sFlip) = UnitSpriteAtlas.resolveFrame(info: soldier, orientation: -128)
        #expect(s == Int(soldier.groundSpriteID) + 6)
        #expect(sFlip == false)
        // W (octant 6 → bucket 1 with flip). phase=0 → offset 3.
        let (w, wFlip) = UnitSpriteAtlas.resolveFrame(info: soldier, orientation: -64)
        #expect(w == Int(soldier.groundSpriteID) + 3)
        #expect(wFlip == true)
        // spriteOffset phase 1 bumps within the bucket: offset 3 + 1 = 4.
        let (ePhase1, _) = UnitSpriteAtlas.resolveFrame(
            info: soldier, orientation: 64, spriteOffset: 1
        )
        #expect(ePhase1 == Int(soldier.groundSpriteID) + 4)
    }

    @MainActor
    @Test("UnitSpriteAtlas loads the full UNITS.SHP range on a real install")
    func atlasLoadsRealInstall() async throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let atlas = try UnitSpriteAtlas(loader: assets)

        // 111..354 should all be populated (the UNITS[1,2].SHP range).
        #expect(atlas.texture(at: 111) != nil)   // UNITS2.SHP start (tank base)
        #expect(atlas.texture(at: 238) != nil)   // UNITS.SHP start (quad base)
        #expect(atlas.texture(at: 283) != nil)   // carryall idle
        #expect(atlas.texture(at: 253) != nil)   // MCV idle
        // 0..110 are non-unit slots — nil.
        #expect(atlas.texture(at: 0) == nil)
        #expect(atlas.texture(at: 100) == nil)
        // 355+ out of range.
        #expect(atlas.texture(at: 400) == nil)
    }
}
