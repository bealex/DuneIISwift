import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Slice 6 — `Structure_BuildObject`'s headless state-setup path (start a factory building a concrete
/// object) + `Structure_CancelBuild`. The GUI factory-window sentinels are deferred to Phase 6.
@Suite("Structure_BuildObject headless setup")
struct BuildObjectTests {
    private let info = ScriptInfo(program: [ UInt16 ](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> (GameState, UnitCombat) {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100; s.houses[0].structuresBuilt = 0xFFFFFF
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    private func addFactory(_ s: inout GameState, _ type: StructureType, house: UInt8 = 0) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        s.structures[slot].state = .idle
        s.structures[slot].objectType = 0
        s.structures[slot].o.linkedID = 0xFF
        return slot
    }

    @Test("a light factory starts building a unit: BUSY + linked off-map product + countDown")
    func buildUnit() {
        var (s, combat) = base()
        let fac = addFactory(&s, .lightVehicle)
        #expect(combat.structureBuildObject(slot: fac, objectType: UInt16(UnitType.trike.rawValue), in: &s))
        #expect(s.structures[fac].state == .busy)
        #expect(s.structures[fac].objectType == UInt16(UnitType.trike.rawValue))
        #expect(s.structures[fac].countDown == UInt16(truncatingIfNeeded: Int(UnitInfo[.trike].o.buildTime) << 8))
        let product = Int(s.structures[fac].o.linkedID)
        #expect(s.units[product].o.type == UInt8(UnitType.trike.rawValue))
        #expect(s.units[product].o.flags.contains(.isNotOnMap))  // queued inside the factory
    }

    @Test("a construction yard starts building a structure (the product is created off-map)")
    func buildStructure() {
        var (s, combat) = base()
        let cy = addFactory(&s, .constructionYard)
        #expect(combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.windtrap.rawValue), in: &s))
        #expect(s.structures[cy].state == .busy)
        let product = Int(s.structures[cy].o.linkedID)
        #expect(s.structures[product].o.type == UInt8(StructureType.windtrap.rawValue))
        #expect(s.structures[product].o.flags.contains(.isNotOnMap))
    }

    @Test("building is a no-op while the factory already has a queued object")
    func alreadyBuilding() {
        var (s, combat) = base()
        let fac = addFactory(&s, .lightVehicle)
        #expect(combat.structureBuildObject(slot: fac, objectType: UInt16(UnitType.trike.rawValue), in: &s))
        let firstProduct = s.structures[fac].o.linkedID
        // Same type again → linkedID present → returns false, keeps the existing build.
        #expect(!combat.structureBuildObject(slot: fac, objectType: UInt16(UnitType.trike.rawValue), in: &s))
        #expect(s.structures[fac].o.linkedID == firstProduct)
    }

    @Test("a GUI factory-window sentinel (0xFFFF) is a deferred no-op")
    func sentinelDeferred() {
        var (s, combat) = base()
        let fac = addFactory(&s, .lightVehicle)
        #expect(!combat.structureBuildObject(slot: fac, objectType: 0xFFFF, in: &s))
        #expect(s.structures[fac].o.linkedID == 0xFF)  // nothing queued
        #expect(s.structures[fac].state == .idle)
    }

    @Test("a non-factory structure cannot build")
    func nonFactory() {
        var (s, combat) = base()
        let wt = addFactory(&s, .windtrap)  // windtrap is not a factory
        #expect(!combat.structureBuildObject(slot: wt, objectType: UInt16(UnitType.trike.rawValue), in: &s))
    }

    @Test("cancelBuild frees the queued product, refunds the unbuilt remainder, and clears the link")
    func cancelBuild() {
        var (s, combat) = base()
        let fac = addFactory(&s, .lightVehicle)
        _ = combat.structureBuildObject(slot: fac, objectType: UInt16(UnitType.trike.rawValue), in: &s)
        let product = Int(s.structures[fac].o.linkedID)
        // Half-built: countDown is half of buildTime<<8 ⇒ refund ≈ half the build cost.
        s.structures[fac].countDown = UInt16(truncatingIfNeeded: Int(UnitInfo[.trike].o.buildTime) << 8) / 2
        s.houses[0].credits = 0
        s.structureCancelBuild(fac)
        #expect(s.structures[fac].o.linkedID == 0xFF)
        #expect(s.structures[fac].countDown == 0)
        #expect(!s.units[product].o.flags.contains(.used))  // product freed
        #expect(s.houses[0].credits > 0)  // partial refund
    }
}
