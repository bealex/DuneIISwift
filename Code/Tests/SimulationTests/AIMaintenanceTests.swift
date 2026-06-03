import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// AI structure maintenance — the tail of OpenDUNE's `GameLoop_Structure` per-structure body
/// (`structure.c:232` auto-place + `:308` auto-repair/auto-build), plus the `Structure_Remove` rebuild-queue
/// record (`structure.c:1336`) and `Structure_AI_PickNextToBuild` (`structure.c:1980`). All no-ops for the
/// player and for houses that aren't `isAIActive`.
@Suite("AI structure maintenance")
struct AIMaintenanceTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    /// An `isAIActive`, non-player house (1) with money + capacity.
    private func aiState() -> GameState {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 1)
        s.houses[1].flags.insert(.isAIActive)
        s.houses[1].credits = 5000
        s.houses[1].unitCountMax = 100
        s.houses[1].structuresBuilt = 0xFFFFFF
        return s
    }

    private func addStructure(_ s: inout GameState, _ type: StructureType, house: UInt8 = 1) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        s.structures[slot].o.flags.insert(.allocated)
        s.structures[slot].state = .idle
        s.structures[slot].objectType = 0
        s.structures[slot].o.linkedID = 0xFF
        s.structures[slot].upgradeLevel = 3  // an AI factory gets the full upgrade at Structure_Create
        return slot
    }

    @Test("Structure_Remove records the lost structure's type + position in the rebuild queue")
    func removeRecordsRebuild() {
        var s = aiState()
        let win = addStructure(&s, .windtrap)
        let packed = Tile32.packXY(x: 20, y: 20)
        s.structures[win].o.position = Tile32.unpack(packed)
        s.structureRemove(win)
        #expect(s.houses[1].aiStructureRebuild[0][0] == UInt16(StructureType.windtrap.rawValue))
        #expect(s.houses[1].aiStructureRebuild[0][1] == packed)
    }

    @Test("a construction yard picks the first buildable type from the rebuild queue")
    func pickRebuildForCY() {
        var s = aiState()
        let cy = addStructure(&s, .constructionYard)
        s.houses[1].aiStructureRebuild[0] = [ UInt16(StructureType.windtrap.rawValue), Tile32.packXY(x: 20, y: 20) ]
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        #expect(sm.structureAIPickNextToBuild(cy) == UInt16(StructureType.windtrap.rawValue))
    }

    @Test("an empty rebuild queue yields nothing to build for a construction yard")
    func pickNothingForEmptyQueue() {
        var s = aiState()
        let cy = addStructure(&s, .constructionYard)
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        #expect(sm.structureAIPickNextToBuild(cy) == nil)
    }

    @Test("a unit factory picks a buildable unit")
    func pickUnitForFactory() {
        var s = aiState()
        let fac = addStructure(&s, .lightVehicle)
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        let pick = sm.structureAIPickNextToBuild(fac)
        #expect(pick != nil)
        let buildable = Set(sm.buildables(forStructure: fac).map(\.objectType))
        #expect(buildable.contains(pick!))
    }

    @Test("maintenance auto-repairs an AI structure below half health")
    func autoRepair() {
        var s = aiState()
        let win = addStructure(&s, .windtrap)
        s.structures[win].o.hitpoints = StructureInfo[.windtrap].o.hitpoints / 2 - 1  // below 50%
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.aiStructureMaintenance(win)
        #expect(sm.state.structures[win].o.flags.contains(.repairing))
    }

    @Test("maintenance starts a build on an idle AI factory")
    func autoBuild() {
        var s = aiState()
        let fac = addStructure(&s, .lightVehicle)
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.aiStructureMaintenance(fac)
        #expect(sm.state.structures[fac].o.linkedID != 0xFF)  // a product was queued
        #expect(sm.state.structures[fac].state == .busy)
    }

    @Test("maintenance is a no-op for a player-owned factory")
    func playerNoBuild() {
        var s = aiState()
        s.houses[1].flags.remove(.isAIActive)  // make house 1 the (non-AI) player path
        s.playerHouseID = 1
        let fac = addStructure(&s, .lightVehicle, house: 1)
        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.aiStructureMaintenance(fac)
        #expect(sm.state.structures[fac].o.linkedID == 0xFF)
    }

    @Test("a finished AI construction yard auto-places its product at the remembered position")
    func autoPlace() {
        var s = aiState()
        let cy = addStructure(&s, .constructionYard)
        let packed = Tile32.packXY(x: 24, y: 24)
        // A finished windtrap product, linked + ready, remembered in the rebuild queue.
        let product = s.structureAllocate(
            index: Pool.structureIndexInvalid,
            type: UInt8(StructureType.windtrap.rawValue)
        )!
        s.structures[product].o.houseID = 1
        s.structures[product].o.flags.insert(.isNotOnMap)
        s.structures[cy].o.linkedID = UInt8(truncatingIfNeeded: Int(s.structures[product].o.index))
        s.structures[cy].state = .ready
        s.houses[1].aiStructureRebuild[0] = [ UInt16(StructureType.windtrap.rawValue), packed ]

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.aiStructureMaintenance(cy)
        #expect(sm.state.structures[cy].o.linkedID == 0xFF)  // CY released the product
        #expect(sm.state.houses[1].aiStructureRebuild[0][0] == 0)  // queue slot cleared
        #expect(!sm.state.structures[product].o.flags.contains(.isNotOnMap))  // product is now on the map
    }
}
