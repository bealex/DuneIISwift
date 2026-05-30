import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// The last three unit-script SEAMs: `MCVDeploy` (0x09, via `Structure_Create`/`Place`/`IsValidBuildLocation`),
/// `RandomSoldier` (0x21), `CallUnitByType` (0x23). Terrain forced via groundTileID (16 → entirely rock,
/// which `isValidForStructure2` — structures build on rock, not sand).
@Suite("MCV deploy + RandomSoldier + CallUnitByType")
struct MCVDeployTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base(rock: Bool = false) -> (GameState, UnitCombat) {
        var s = GameState()
        var t = TileIDs(); t.landscape = 0; t.builtSlab = 1000; t.bloom = 2000; t.wall = 3000; t.veiled = 4000
        s.tileIDs = t
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 200
        if rock { for i in s.map.indices { s.map[i].groundTileID = 16 } }   // entirely rock → buildable
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    @Test("structureIsValidBuildLocation: rock is valid, an occupied footprint is not")
    func validBuildLocation() {
        var (s, combat) = base(rock: true)
        let pos = Tile32.packXY(x: 20, y: 20)
        #expect(combat.structureIsValidBuildLocation(pos, type: .constructionYard, in: s) != 0)   // valid on rock
        // Stamp a unit onto the footprint → invalid.
        let blocker = s.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        s.map[Int(pos)].hasUnit = true; s.map[Int(pos)].index = UInt8(blocker + 1)
        #expect(combat.structureIsValidBuildLocation(pos, type: .constructionYard, in: s) == 0)
    }

    @Test("MCVDeploy creates a construction yard on rock and removes the MCV")
    func mcvDeploys() {
        var (s, combat) = base(rock: true)
        let mcv = s.unitAllocate(index: 0, type: UInt8(UnitType.mcv.rawValue), houseID: 0)!
        s.units[mcv].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        let ret = combat.mcvDeploy(slot: mcv, in: &s)
        #expect(ret == 1)
        #expect(!s.units[mcv].o.flags.contains(.used))   // MCV consumed
        #expect(s.structures.contains { $0.o.flags.contains(.used)
            && $0.o.type == UInt8(StructureType.constructionYard.rawValue) })
    }

    @Test("MCVDeploy fails (returns 0) on un-buildable sand and keeps the MCV")
    func mcvDeployFailsOnSand() {
        var (s, combat) = base(rock: false)   // default ground = sand (not isValidForStructure2)
        let mcv = s.unitAllocate(index: 0, type: UInt8(UnitType.mcv.rawValue), houseID: 0)!  // house 0 = player
        s.units[mcv].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        #expect(combat.mcvDeploy(slot: mcv, in: &s) == 0)
        #expect(s.units[mcv].o.flags.contains(.used))    // still there
    }

    @Test("RandomSoldier spawns soldiers over repeated rolls")
    func randomSoldierSpawns() throws {
        var (s, combat) = base()
        let spawner = try #require(UnitType.allCases.first { UnitInfo[$0].o.spawnChance > 0 })   // a unit that sprays soldiers
        let u = s.unitAllocate(index: 0, type: UInt8(spawner.rawValue), houseID: 0)!
        s.units[u].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        for _ in 0 ..< 200 { _ = combat.randomSoldier(slot: u, action: UInt16(ActionType.guard_.rawValue), in: &s) }
        let soldiers = s.units.filter { $0.o.flags.contains(.used) && $0.o.type == UInt8(UnitType.soldier.rawValue) }
        #expect(!soldiers.isEmpty)
    }

    @Test("CallUnitByType: returns an existing link, and 0 for a non-pickup-able caller")
    func callUnitByTypeGuards() {
        var (s, combat) = base()
        let tank = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!  // tank: not canBePickedUp
        s.units[tank].o.script.variables[4] = 1234
        #expect(combat.callUnitByType(slot: tank, type: UInt16(UnitType.carryall.rawValue), in: &s) == 1234)  // existing link
        s.units[tank].o.script.variables[4] = 0
        #expect(combat.callUnitByType(slot: tank, type: UInt16(UnitType.carryall.rawValue), in: &s) == 0)      // can't be picked up
    }
}
