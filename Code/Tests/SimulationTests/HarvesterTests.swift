import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// The harvester loop natives: `Script_Unit_Harvest` (0x2A), `Script_General_SearchSpice` (0x29), and
/// `Script_Unit_GoToClosestStructure` (0x33, → an empty refinery). Terrain is forced via `groundTileID`
/// (`landscapeSpriteMap`: 0 → sand, 49 → spice, 65 → thick spice).
@Suite("Harvester loop")
struct HarvesterTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func tileIDs() -> TileIDs {
        var t = TileIDs(); t.landscape = 0; t.builtSlab = 1000; t.bloom = 2000; t.wall = 3000; t.veiled = 4000
        return t
    }

    private func setup(harvesterTile: UInt16 = 0) -> (GameState, Int, UnitMovement) {
        var s = GameState()
        s.tileIDs = tileIDs()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: UInt8(UnitType.harvester.rawValue), houseID: 0)!
        let packed = Tile32.packXY(x: 20, y: 20)
        s.units[slot].o.position = Tile32.unpack(packed)
        s.map[Int(packed)].groundTileID = harvesterTile
        return (s, slot, UnitMovement(scriptInfo: info))
    }

    @Test("harvest on spice sets inTransport and gathers over time")
    func harvestGathers() {
        var (s, slot, m) = setup(harvesterTile: 65)  // thick spice
        for _ in 0 ..< 200 { _ = m.harvest(slot: slot, in: &s) }
        #expect(s.units[slot].o.flags.contains(.inTransport))
        #expect(s.units[slot].amount > 0 && s.units[slot].amount <= 100)
    }

    @Test("harvest off spice is a no-op")
    func harvestOffSpice() {
        var (s, slot, m) = setup(harvesterTile: 0)  // sand
        let r = m.harvest(slot: slot, in: &s)
        #expect(r == 0)
        #expect(!s.units[slot].o.flags.contains(.inTransport))
        #expect(s.units[slot].amount == 0)
    }

    @Test("a full harvester (amount 100) doesn't gather")
    func harvestFull() {
        var (s, slot, m) = setup(harvesterTile: 65)
        s.units[slot].amount = 100
        #expect(m.harvest(slot: slot, in: &s) == 0)
    }

    @Test("searchSpice finds nearby spice and returns 0 when none is in range")
    func searchSpice() {
        var (s, slot, m) = setup(harvesterTile: 0)
        #expect(m.searchSpice(slot: slot, radius: 20, in: s) == 0)  // no spice anywhere
        s.map[Int(Tile32.packXY(x: 22, y: 20))].groundTileID = 49  // spice two tiles east
        #expect(m.searchSpice(slot: slot, radius: 20, in: s) != 0)
    }

    @Test("goToClosestStructure sends the harvester to the nearest idle, unlinked refinery")
    func goToRefinery() {
        var (s, slot, _) = setup(harvesterTile: 0)
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[r].o.houseID = 0
        s.structures[r].state = .idle
        s.structures[r].o.position = Tile32.unpack(Tile32.packXY(x: 25, y: 20))  // idle, linkedID 0xFF, var4 0

        let actions = UnitActions()
        let funcs = UnitScriptFunctions(unitPrimitives: DefaultUnitPrimitives())
        var engine = s.units[slot].o.script
        let ret = funcs.goToClosestStructure(
            slot: slot,
            type: UInt16(StructureType.refinery.rawValue),
            scriptInfo: info,
            actions: actions,
            engine: &engine,
            in: &s
        )
        #expect(ret == 1)
        #expect(s.units[slot].actionID == UInt8(ActionType.move.rawValue))
        #expect(s.units[slot].targetMove != 0)  // a destination (the refinery) was set
    }

    @Test("goToClosestStructure skips a busy/linked refinery and returns 0")
    func goToRefinerySkipsBusy() {
        var (s, slot, _) = setup(harvesterTile: 0)
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[r].o.houseID = 0
        s.structures[r].state = .busy  // not idle → skipped
        s.structures[r].o.position = Tile32.unpack(Tile32.packXY(x: 25, y: 20))

        let actions = UnitActions()
        let funcs = UnitScriptFunctions(unitPrimitives: DefaultUnitPrimitives())
        var engine = s.units[slot].o.script
        #expect(
            funcs.goToClosestStructure(
                slot: slot,
                type: UInt16(StructureType.refinery.rawValue),
                scriptInfo: info,
                actions: actions,
                engine: &engine,
                in: &s
            ) == 0
        )
    }
}
