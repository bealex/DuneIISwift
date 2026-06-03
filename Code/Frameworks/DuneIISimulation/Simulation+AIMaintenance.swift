import DuneIIContracts
import DuneIIWorld

public extension Simulation {
    /// The AI structure-maintenance pass that runs in `gameLoopStructure` right after `structureTickStructure`
    /// for each structure (the tail of OpenDUNE's `GameLoop_Structure` per-structure body, `structure.c:232`
    /// + `:308`). Two parts, both no-ops for the player and for non-AI houses:
    ///
    /// 1. **AI construction-yard auto-place** (`structure.c:232`): an AI never hand-places — the moment a
    ///    construction yard's product is READY it is stamped onto the map at the position remembered in the
    ///    house's `aiStructureRebuild` queue (matched by type). If no slot remembers it, the product is
    ///    refunded and freed. (The player path leaves the CY READY awaiting a manual `structurePlaceReady`.)
    /// 2. **AI maintenance** (`structure.c:308`): gated on `isAIActive && allocated && !player && credits != 0`
    ///    — start repairing below 50% HP, and if an idle factory (`countDown == 0 && linkedID == 0xFF`) pick
    ///    the next thing to build (`structureAIPickNextToBuild`) and start it. Because the CY's product is
    ///    auto-placed and `countDown` zeroed in the same pass, an AI rebuilds the next queued structure on the
    ///    very next tick the construction cursor fires — exactly as OpenDUNE chains them.
    mutating func aiStructureMaintenance(_ slot: Int) {
        guard
            let st = StructureType(rawValue: Int(state.structures[slot].o.type)),
            let combat = unitScript?.combat
        else { return }
        let hID = Int(state.structures[slot].o.houseID)
        let si = StructureInfo[st]

        // 1. AI construction-yard auto-place of a finished structure.
        if state.structures[slot].o.houseID != state.playerHouseID, st == .constructionYard,
            state.structures[slot].state == .ready, state.structures[slot].o.linkedID != 0xFF
        {
            let ns = Int(state.structures[slot].o.linkedID)
            state.structures[slot].o.linkedID = 0xFF
            state.structureSetState(slot, .idle)
            let nsType = UInt16(state.structures[ns].o.type)
            var placed = false
            for i in 0 ..< 5 where state.houses[hID].aiStructureRebuild[i][0] == nsType {
                if !combat.structurePlace(ns, position: state.houses[hID].aiStructureRebuild[i][1], in: &state) {
                    continue
                }
                state.houses[hID].aiStructureRebuild[i] = [ 0, 0 ]
                placed = true
                break
            }
            if !placed, let nst = StructureType(rawValue: Int(nsType)) {
                state.houses[hID].credits &+= StructureInfo[nst].o.buildCredits
                state.structureFree(ns)
            }
        }

        // 2. AI maintenance: auto-repair + auto-build when idle.
        guard
            state.houses[hID].flags.contains(.isAIActive),
            state.structures[slot].o.flags.contains(.allocated),
            state.structures[slot].o.houseID != state.playerHouseID,
            state.houses[hID].credits != 0
        else { return }

        if state.structures[slot].o.hitpoints < si.o.hitpoints / 2 {
            _ = state.structureSetRepairingState(slot, state: 1)
        }

        if si.o.flags.contains(.factory), state.structures[slot].countDown == 0,
            state.structures[slot].o.linkedID == 0xFF, let type = structureAIPickNextToBuild(slot)
        {
            combat.structureBuildObject(slot: slot, objectType: type, in: &state)
        }
    }

    /// `Structure_AI_PickNextToBuild` (`structure.c:1980`): what an AI factory should build next, or `nil`
    /// (`0xFFFF`) for nothing. A **construction yard** returns the first buildable type in the house's
    /// `aiStructureRebuild` queue (so the AI only rebuilds what it lost). A **unit factory** picks from its
    /// buildable units with a 25%-random / highest-`priorityBuild` tournament (one `Random256` per buildable,
    /// in unit-type order — the draw order matters), excluding a carryall when the High-Tech already owns one
    /// and the harvester/MCV at the Heavy-Vehicle.
    mutating func structureAIPickNextToBuild(_ slot: Int) -> UInt16? {
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return nil }
        let hID = Int(state.structures[slot].o.houseID)
        let buildable = buildables(forStructure: slot)

        if st == .constructionYard {
            for i in 0 ..< 5 {
                let type = state.houses[hID].aiStructureRebuild[i][0]
                if type == 0 { continue }
                if buildable.contains(where: { $0.isStructure && $0.objectType == type }) { return type }
            }
            return nil
        }

        var set = Set(buildable.lazy.filter { !$0.isStructure }.map(\.objectType))
        if st == .highTech {
            var find = PoolFind(houseID: UInt8(hID), type: UInt16(UnitType.carryall.rawValue))
            if state.unitFind(&find) != nil { set.remove(UInt16(UnitType.carryall.rawValue)) }
        }
        if st == .heavyVehicle {
            set.remove(UInt16(UnitType.harvester.rawValue))
            set.remove(UInt16(UnitType.mcv.rawValue))
        }

        var pick: UInt16? = nil
        for i in 0 ..< 27 {  // UNIT_MAX
            let raw = UInt16(i)
            if !set.contains(raw) { continue }
            if state.random256.next() % 4 == 0 { pick = raw }
            if let cur = pick, let curType = UnitType(rawValue: Int(cur)), let candidate = UnitType(rawValue: i),
                UnitInfo[candidate].o.priorityBuild <= UnitInfo[curType].o.priorityBuild
            {
                continue
            }
            pick = raw
        }
        return pick
    }
}
