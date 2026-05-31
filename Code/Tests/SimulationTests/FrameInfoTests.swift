import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// `Simulation.makeFrameInfo()` — the `sim → render` snapshot builder. Asserts each layer of the
/// `GameState` is surfaced into the presentation-neutral `FrameInfo`: terrain tiles, units (with the
/// `UnitSprites`-resolved body/turret layers + effective house), structures, houses, the transient
/// effects (smoke + explosions), and the viewport origin in sub-tile units.
/// See `Documentation/Architecture/FrameInfo.md`.
@Suite("FrameInfo snapshot")
struct FrameInfoTests {
    /// A simulation with one tank, one windtrap, one active house, one explosion, fog + a viewport.
    private func scene() -> Simulation {
        var sim = Simulation(random256Seed: 0)

        // A combat tank at tile (10,12), facing East, with a turret heading North-East and half HP.
        var tank = Unit()
        tank.o.index = 0
        tank.o.type = UInt8(UnitType.tank.rawValue)
        tank.o.flags = [.used, .allocated, .isUnit]
        tank.o.houseID = UInt8(HouseID.atreides.rawValue)
        tank.o.position = Tile32(x: 10 * 256 + 0x80, y: 12 * 256 + 0x80)
        tank.o.hitpoints = 100
        tank.orientation[0].current = 64       // East
        tank.orientation[1].current = 0        // turret North
        sim.state.units[0] = tank

        // A windtrap (corner position), Ordos, full of HP.
        var wt = Structure()
        wt.o.index = 0
        wt.o.type = UInt8(StructureType.windtrap.rawValue)
        wt.o.flags = [.used, .allocated]
        wt.o.houseID = UInt8(HouseID.ordos.rawValue)
        wt.o.position = Tile32(x: 20 * 256, y: 8 * 256)
        wt.o.hitpoints = 175
        wt.hitpointsMax = 200
        sim.state.structures[0] = wt

        // An active Ordos house with credits + power.
        var ordos = House()
        ordos.index = UInt8(HouseID.ordos.rawValue)
        ordos.flags = [.used]
        ordos.credits = 1500
        ordos.creditsStorage = 1000
        ordos.powerProduction = 100
        ordos.powerUsage = 30
        sim.state.houses[Int(HouseID.ordos.rawValue)] = ordos

        // A terrain tile with an overlay and revealed fog at packed (5,5).
        let packed = Int(Tile32.packXY(x: 5, y: 5))
        sim.state.map[packed].groundTileID = 123
        sim.state.map[packed].overlayTileID = 7
        sim.state.map[packed].isUnveiled = true

        // One active explosion frame.
        sim.state.explosions[0].active = true
        sim.state.explosions[0].spriteID = 250
        sim.state.explosions[0].position = Tile32(x: 15 * 256 + 0x80, y: 15 * 256 + 0x80)

        sim.state.viewportPosition = Tile32.packXY(x: 3, y: 4)
        sim.state.timerGame = 42
        return sim
    }

    @Test("tick + map dimensions + viewport in sub-tile units")
    func frameHeader() {
        let f = scene().makeFrameInfo()
        #expect(f.tick == 42)
        #expect(f.mapWidth == 64 && f.mapHeight == 64)
        #expect(f.tiles.count == 64 * 64)
        #expect(f.viewportX == 3 * 256 && f.viewportY == 4 * 256)
    }

    @Test("the veil tile id is carried for the renderer's fog test")
    func veiledTileIndex() {
        var sim = scene()
        sim.state.tileIDs.veiled = 41
        #expect(sim.makeFrameInfo().veiledTileIndex == 41)
    }

    @Test("fogEdgeMask sets a bit per off-map / veiled neighbour (N,E,S,W)")
    func fogEdgeMask() {
        let w = 64, h = 64
        // All neighbours revealed ⇒ no edges.
        #expect(Simulation.fogEdgeMask(packed: Int(Tile32.packXY(x: 10, y: 10)), width: w, height: h) { _ in true } == 0)
        // The (0,0) corner: N and W are off-map ⇒ bit 0 (N) | bit 3 (W) = 9, even with all tiles revealed.
        #expect(Simulation.fogEdgeMask(packed: 0, width: w, height: h) { _ in true } == 0b1001)
        // Only the north neighbour veiled ⇒ bit 0.
        let centre = Int(Tile32.packXY(x: 10, y: 10))
        #expect(Simulation.fogEdgeMask(packed: centre, width: w, height: h) { $0 != centre - w } == 0b0001)
        // Only the west neighbour veiled ⇒ bit 3.
        #expect(Simulation.fogEdgeMask(packed: centre, width: w, height: h) { $0 != centre - 1 } == 0b1000)
    }

    @Test("makeFrameInfo derives a fog-edge sprite for a revealed tile bordering the unknown")
    func fogEdges() {
        var sim = scene()
        sim.state.tileIDs.fogEdges = (0 ..< 16).map { UInt16(500 + $0) }
        // Reveal a 3×3 block around (10,10).
        for dy in -1 ... 1 { for dx in -1 ... 1 {
            sim.state.map[Int(Tile32.packXY(x: UInt16(10 + dx), y: UInt16(10 + dy)))].isUnveiled = true
        } }
        let f = sim.makeFrameInfo()
        func edge(_ x: Int, _ y: Int) -> Int { f.tiles[Int(Tile32.packXY(x: UInt16(x), y: UInt16(y)))].fogEdgeSpriteIndex }
        #expect(edge(10, 10) == 0)             // interior: all neighbours revealed ⇒ no edge
        #expect(edge(10, 9) == 500 + 0b0001)   // top-middle: only N veiled ⇒ mask 1
        #expect(edge(9, 9) == 500 + 0b1001)    // top-left corner: N and W veiled ⇒ mask 9
        #expect(edge(11, 11) == 500 + 0b0110)  // bottom-right corner: E and S veiled ⇒ mask 6
    }

    @Test("terrain tile surfaces ground + overlay + fog")
    func terrain() {
        let f = scene().makeFrameInfo()
        let t = f.tiles[Int(Tile32.packXY(x: 5, y: 5))]
        #expect(t.groundSpriteIndex == 123)
        #expect(t.overlaySpriteIndex == 7)
        #expect(t.isUnveiled)
        // An untouched tile is veiled with no overlay.
        let empty = f.tiles[0]
        #expect(empty.overlaySpriteIndex == 0 && !empty.isUnveiled)
    }

    @Test("unit: position, house, hp, and the viewport-resolved sprite layers")
    func unit() throws {
        let f = scene().makeFrameInfo()
        let u = try #require(f.units.first)
        #expect(u.id == 0)
        #expect(u.type == .tank)
        #expect(u.house == .atreides)
        #expect(u.positionX == 10 * 256 + 0x80 && u.positionY == 12 * 256 + 0x80)
        #expect(u.hitpoints == 100)
        #expect(u.hitpointsMax == Int(UnitInfo[.tank].o.hitpoints))
        #expect(!u.isSmoking)
        // The layers match the UnitSprites resolver (tank East = body 113, turret North = 116).
        let resolved = try #require(UnitSprites.info(for: scene().state.units[0]))
        #expect(u.body == resolved.body)
        #expect(u.turret == resolved.turret)
        #expect(u.body.spriteIndex == 113)
        #expect(u.turret?.spriteIndex == 116)
    }

    @Test("deviated unit reports its captor's (Ordos) house")
    func deviatedHouse() throws {
        var sim = scene()
        sim.state.units[0].deviated = 120        // active deviation → Unit_GetHouseID == Ordos in 1.07
        let u = try #require(sim.makeFrameInfo().units.first)
        #expect(u.house == .ordos)
    }

    @Test("structure: corner position, type, house, hp")
    func structure() throws {
        let f = scene().makeFrameInfo()
        let s = try #require(f.structures.first)
        #expect(s.id == 0)
        #expect(s.type == .windtrap)
        #expect(s.house == .ordos)
        #expect(s.positionX == 20 * 256 && s.positionY == 8 * 256)
        #expect(s.hitpoints == 175 && s.hitpointsMax == 200)
    }

    @Test("house economy is surfaced for the game-info panel")
    func house() throws {
        let f = scene().makeFrameInfo()
        let h = try #require(f.houses.first { $0.id == .ordos })
        #expect(h.credits == 1500)
        #expect(h.creditsStorage == 1000)
        #expect(h.powerProduction == 100)
        #expect(h.powerUsage == 30)
        #expect(f.houses.count == 1)        // only the one `.used` house
    }

    @Test("active explosion becomes an effect at its world position")
    func explosionEffect() throws {
        let f = scene().makeFrameInfo()
        let e = try #require(f.effects.first { $0.sprite.spriteIndex == 250 })
        #expect(e.positionX == 15 * 256 + 0x80 && e.positionY == 15 * 256 + 0x80)
    }

    @Test("smoking unit emits a smoke effect above it; quiet unit does not")
    func smokeEffect() throws {
        var sim = scene()
        sim.state.units[0].o.flags.insert(.isSmoking)
        sim.state.units[0].spriteOffset = 2                  // frame 180 + 2 = 182
        let f = sim.makeFrameInfo()
        let smoke = try #require(f.effects.first { $0.sprite.spriteIndex == 182 })
        #expect(smoke.sprite.offsetY == -14)
        #expect(smoke.positionX == 10 * 256 + 0x80)
        #expect(f.units.first?.isSmoking == true)
        // Folding: spriteOffset 3 → frame 183 → 181.
        sim.state.units[0].spriteOffset = 3
        #expect(sim.makeFrameInfo().effects.contains { $0.sprite.spriteIndex == 181 })
    }

    @Test("hidden (isNotOnMap) units are omitted — no phantom at a stale position")
    func hiddenUnitOmitted() {
        var sim = scene()
        sim.state.units[0].o.flags.insert(.isNotOnMap)     // e.g. a harvester carried in a carryall
        #expect(sim.makeFrameInfo().units.isEmpty)
    }

    @Test("a carryall is flagged as an air unit for the renderer's z-order")
    func airUnitFlag() throws {
        var sim = scene()
        sim.state.units[0].o.type = UInt8(UnitType.carryall.rawValue)
        let u = try #require(sim.makeFrameInfo().units.first)
        #expect(u.isAirUnit)
        #expect(try #require(sim.makeFrameInfo().units.first { $0.type == .carryall }).isAirUnit)
    }

    @Test("a harvester harvesting on spice surfaces the overlay layer; off spice it does not")
    func harvesterOverlay() throws {
        var sim = scene()
        // Synthetic tile ids so the harvester's tile resolves to LST_SPICE: landscape base 100, the spice
        // sprite offset is 49 (`landscapeSpriteMap[49] == 8`), wall/slab/bloom kept out of range.
        sim.state.tileIDs.landscape = 100
        sim.state.tileIDs.wall = 1000
        sim.state.tileIDs.builtSlab = 0xFFFE
        sim.state.tileIDs.bloom = 0xFFFD
        sim.state.tileIDs.veiled = 0xFFFC
        let packed = Int(sim.state.units[0].o.position.packed)
        sim.state.map[packed].groundTileID = 149          // 100 + 49 → spice
        sim.state.units[0].o.type = UInt8(UnitType.harvester.rawValue)
        sim.state.units[0].orientation[0].current = 0
        sim.state.units[0].actionID = UInt8(ActionType.harvest.rawValue)
        sim.state.units[0].spriteOffset = 1

        let overlay = try #require(sim.makeFrameInfo().units.first?.overlay)
        #expect(overlay.spriteIndex == 0xDF + 1)          // (spriteOffset % 3) + 0xDF, North

        // Move it onto rock (offset 0 → normalSand is 0; use a tile far outside the landscape range → rock).
        sim.state.map[packed].groundTileID = 50           // offset -50 → entirelyRock, not spice
        #expect(sim.makeFrameInfo().units.first?.overlay == nil)
    }

    @Test("sandworm shimmer (blurTile) is omitted from the unit list")
    func sandwormOmitted() {
        var sim = scene()
        sim.state.units[1].o.index = 1
        sim.state.units[1].o.type = UInt8(UnitType.sandworm.rawValue)
        sim.state.units[1].o.flags = [.used, .allocated, .isUnit]
        let f = sim.makeFrameInfo()
        #expect(f.units.allSatisfy { $0.type != .sandworm })
        #expect(f.units.count == 1)
    }
}
