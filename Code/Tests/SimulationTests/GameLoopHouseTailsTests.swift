import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Slice 5 — the `GameLoop_House` tails: `Map_FindLocationTile`, `Unit_CreateWrapper`,
/// `House_EnsureHarvesterAvailable`, the starport stock bump, and the frigate delivery.
@Suite("GameLoop_House tails")
struct GameLoopHouseTailsTests {
    private let info = ScriptInfo(program: [ UInt16 ](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func combatBase() -> (GameState, UnitCombat) {
        var s = GameState(random256Seed: 0x55, randomLCGSeed: 0x55)
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    private func addStructure(_ s: inout GameState, _ type: StructureType, house: UInt8, at packed: UInt16? = nil)
        -> Int
    {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        if let packed { s.structures[slot].o.position = Tile32.unpack(packed) }
        return slot
    }

    // MARK: - Map_FindLocationTile

    @Test("findLocationTile places edge spawns on the right map border")
    func findLocationEdges() {
        var (s, move) = (combatBase().0, DefaultMapPrimitives())
        // Scale-0 map: minX=minY=1, size 62, mapBase 1. North edge → y == minY + 1 == 2.
        let north = move.findLocationTile(0, houseID: 0, in: &s)
        #expect(Tile32.packedY(north) == 2)
        #expect((1 ... 60).contains(Int(Tile32.packedX(north))))
        // West edge → x == minX + 1 == 2.
        let west = move.findLocationTile(3, houseID: 0, in: &s)
        #expect(Tile32.packedX(west) == 2)
    }

    // MARK: - Unit_CreateWrapper

    @Test("unitCreateWrapper ferries a ground unit: returns the cargo, riding a linked carryall")
    func createWrapperGround() {
        var (s, combat) = combatBase()
        // OpenDUNE's Unit_CreateWrapper returns the ferried CARGO (the harvester), not the carryall — so a
        // caller stamping `originEncoded` lands it on the harvester (its home refinery), not the carryall.
        let ret = combat.unitCreateWrapper(houseID: 0, type: .harvester, destination: 0, in: &s)
        let cargo = try! #require(ret)
        #expect(s.units[cargo].o.type == UInt8(UnitType.harvester.rawValue))
        #expect(s.units[cargo].amount == 1)  // a fresh harvester carries 1
        #expect(s.units[cargo].o.flags.contains(.isNotOnMap))  // riding inside
        // The carryall (on-map, in transport) links to that cargo.
        var f = PoolFind(houseID: 0, type: UInt16(UnitType.carryall.rawValue))
        let carryall = try! #require(s.unitFind(&f))
        #expect(s.units[carryall].o.flags.contains(.inTransport))
        #expect(Int(s.units[carryall].o.linkedID) == cargo)
    }

    @Test("unitCreateWrapper spawns a winger directly (no carryall)")
    func createWrapperWinger() {
        var (s, combat) = combatBase()
        let made = combat.unitCreateWrapper(houseID: 0, type: .carryall, destination: 0, in: &s)
        let u = try! #require(made)
        #expect(s.units[u].o.type == UInt8(UnitType.carryall.rawValue))
        #expect(s.units[u].o.flags.contains(.byScenario))
        #expect(s.units[u].o.linkedID == 0xFF)  // a winger isn't ferried
    }

    // MARK: - House_EnsureHarvesterAvailable

    @Test("EnsureHarvesterAvailable dispatches a harvester when a refinery has none")
    func ensureHarvesterSpawns() {
        var (s, combat) = combatBase()
        _ = addStructure(&s, .refinery, house: 0, at: Tile32.packXY(x: 30, y: 30))
        #expect(!s.unitIsTypeOnMap(houseID: 0, typeID: UInt8(UnitType.carryall.rawValue)))
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        // A carryall (ferrying the new harvester) was dispatched to the map.
        #expect(s.unitIsTypeOnMap(houseID: 0, typeID: UInt8(UnitType.carryall.rawValue)))
    }

    @Test("EnsureHarvesterAvailable is a no-op when a harvester is already on the map")
    func ensureHarvesterNoop() {
        var (s, combat) = combatBase()
        _ = addStructure(&s, .refinery, house: 0, at: Tile32.packXY(x: 30, y: 30))
        let harv = s.unitAllocate(index: 0, type: UInt8(UnitType.harvester.rawValue), houseID: 0)!
        s.units[harv].o.position = Tile32.unpack(Tile32.packXY(x: 31, y: 30))
        s.unitUpdateMap(1, harv)
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        #expect(!s.unitIsTypeOnMap(houseID: 0, typeID: UInt8(UnitType.carryall.rawValue)))  // none dispatched
    }

    // MARK: - GameLoop_House tail bodies (driven through a tick)

    @Test("the starport-availability tick bumps one in-stock unit type")
    func starportStockBump() {
        var s = combatBase().0
        s.starportAvailable = Array(repeating: 1, count: 27)  // all in stock ⇒ whichever is drawn bumps
        s.houseTick.house = 1_000_000  // isolate the starport-availability body
        s.houseTick.powerMaintenance = 1_000_000
        var sim = Simulation(state: s, scriptInfo: info)
        sim.tick()  // tick 1 → starportAvailability fires
        #expect(sim.state.starportAvailable.map(Int.init).reduce(0, +) == 27 + 1)
    }

    @Test("the starport frigate delivery sends a frigate and clears the linked cargo")
    func frigateDelivery() {
        var s = combatBase().0
        let starport = addStructure(&s, .starport, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.structures[starport].o.linkedID = 0xFF  // free to receive a frigate
        let cargo = s.unitAllocate(index: 5, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        s.units[cargo].o.flags.insert(.isNotOnMap)
        s.houses[0].starportLinkedID = UInt16(s.units[cargo].o.index)
        s.houses[0].starportTimeLeft = 1  // elapses to 0 this tick
        s.houseTick.house = 1_000_000  // isolate the starport body
        s.houseTick.powerMaintenance = 1_000_000

        var sim = Simulation(state: s, scriptInfo: info)
        sim.tick()  // tick 1 → tickStarport fires

        #expect(sim.state.houses[0].starportLinkedID == 0xFFFF)  // delivery consumed the link
        #expect(sim.state.unitIsTypeOnMap(houseID: 0, typeID: UInt8(UnitType.frigate.rawValue)))
    }
}
