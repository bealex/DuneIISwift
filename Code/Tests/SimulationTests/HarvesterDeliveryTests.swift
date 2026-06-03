import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// The harvester **delivery** lifecycle — `House_EnsureHarvesterAvailable` (`UnitCombat`): when a house has
/// a refinery but no harvester (none on the map, none docked, none in a carryall), a fresh harvester is
/// created and **flown in by a carryall** (`Unit_CreateWrapper`). Covers: a refinery spawning a harvester,
/// the carryall transport, and re-spawning after the last harvester is destroyed. The full harvest→refine
/// loop is `HarvesterCycleTests`.
@Suite("Harvester delivery")
struct HarvesterDeliveryTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> (GameState, UnitCombat) {
        var s = GameState(); s.playerHouseID = 0; s.mapScale = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    @discardableResult
    private func addRefinery(
        _ s: inout GameState,
        house: UInt8 = 0,
        at packed: UInt16 = Tile32.packXY(x: 30, y: 30)
    ) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        let corner = Tile32.unpack(packed)
        s.structures[slot].o.houseID = house
        s.structures[slot].state = .idle
        s.structures[slot].o.hitpoints = StructureInfo[.refinery].o.hitpoints
        s.structures[slot].hitpointsMax = StructureInfo[.refinery].o.hitpoints
        s.structures[slot].o.position = Tile32(x: corner.x & 0xFF00, y: corner.y & 0xFF00)
        return slot
    }

    private func carryalls(_ s: GameState) -> [Int] {
        s.units.indices.filter {
            s.units[$0].o.flags.contains(.used) && s.units[$0].o.type == UInt8(UnitType.carryall.rawValue)
        }
    }
    private func harvesterType() -> UInt8 { UInt8(UnitType.harvester.rawValue) }

    @Test("a refinery with no harvester summons a carryall carrying a new harvester toward it")
    func refinerySummonsHarvester() throws {
        var (s, combat) = base()
        let ref = addRefinery(&s)
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)

        // One carryall now exists, in transport, carrying an off-map harvester, headed to the refinery.
        let cs = carryalls(s)
        #expect(cs.count == 1)
        let carryall = try #require(cs.first)
        #expect(s.units[carryall].o.flags.contains(.inTransport))
        let cargo = Int(s.units[carryall].o.linkedID)
        #expect(cargo != 0xFF)
        #expect(s.units[cargo].o.type == harvesterType())
        #expect(s.units[cargo].o.flags.contains(.isNotOnMap))  // riding inside the carryall
        #expect(s.units[carryall].targetMove == s.indexEncode(s.structures[ref].o.index, type: .structure))

        // A second check is a no-op — the in-flight delivery already covers the house.
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        #expect(carryalls(s).count == 1)
    }

    @Test("no refinery ⇒ no harvester is summoned")
    func noRefineryNoHarvester() {
        var (s, combat) = base()
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        #expect(carryalls(s).isEmpty)
    }

    @Test("an on-map harvester isn't duplicated; a destroyed one is replaced by a fresh delivery")
    func destroyedHarvesterReplaced() throws {
        var (s, combat) = base()
        addRefinery(&s)
        let harv = s.unitAllocate(index: 0, type: harvesterType(), houseID: 0)!
        s.units[harv].o.position = Tile32.unpack(Tile32.packXY(x: 25, y: 25))

        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        #expect(carryalls(s).isEmpty)  // the live harvester already covers the house

        s.unitRemove(harv)  // the only harvester is destroyed
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &s)
        let cs = carryalls(s)
        #expect(cs.count == 1)  // a replacement delivery is summoned
        let cargo = Int(s.units[try #require(cs.first)].o.linkedID)
        #expect(s.units[cargo].o.type == harvesterType())
    }

    @Test("the carryall flies the summoned harvester to the refinery and delivers it", .timeLimit(.minutes(1)))
    func carryallDeliversHarvester() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        guard
            let unitData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP"))
        else { return }

        let unitInfo = ScriptInfo(try Emc.Program(unitData))
        let buildInfo = ScriptInfo(try Emc.Program(buildData))
        let iconMap = try IconMap(iconData)

        var state = GameState()
        state.playerHouseID = 0
        _ = state.houseAllocate(index: 0)
        state.houses[0].unitCountMax = 100
        state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        state.iconMap = iconMap  // structureUpdateMap needs it to stamp tiles
        state.mapScale = 0
        let ref = addRefinery(&state)
        state.structureUpdateMap(ref)  // stamp it so the carryall can deliver into it

        var sim = Simulation(state: state, scriptInfo: unitInfo, structureScriptInfo: buildInfo)
        let combat = sim.unitScript!.combat
        combat.houseEnsureHarvesterAvailable(houseID: 0, in: &sim.state)

        // Precondition: a carryall is carrying the harvester (off-map) toward the refinery.
        #expect(carryalls(sim.state).count == 1)

        // Fly it in. "Delivered" = the harvester reaches the map — either docked in the refinery
        // (`linkedID` set) or set down on the ground — and is no longer riding the carryall.
        var delivered = false
        for _ in 0 ..< 4000 {
            sim.tick()
            let docked = sim.state.structures[ref].o.linkedID != 0xFF
            let onMap = sim.state.unitIsTypeOnMap(houseID: 0, typeID: harvesterType())
            if docked || onMap { delivered = true; break }
        }
        #expect(delivered, "the carryall never delivered the harvester to the refinery")
    }
}
