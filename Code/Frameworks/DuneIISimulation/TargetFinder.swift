import DuneIIContracts
import DuneIIWorld

/// Auto-target selection — `Unit_FindBestTargetEncoded` + its unit/structure scans and priority scoring
/// (`unit.c`). A faithful, deterministic port (no RNG) used by `Script_Unit_FindBestTarget` (op-`0x1C`):
/// pick the highest-priority enemy unit/structure for `unit`, scored by the target's priority tables
/// over distance, gated by visibility (`seenByHouses`), alliance, and (for air) the `targetAir` flag.
/// Composes the injected map/house primitives + the World pools; returns the encoded target (or 0).
public struct TargetFinder: Sendable {
    public let map: any MapPrimitives
    public let house: any HousePrimitives

    public init(map: any MapPrimitives = DefaultMapPrimitives(),
                house: any HousePrimitives = DefaultHousePrimitives()) {
        self.map = map
        self.house = house
    }

    /// `Unit_FindBestTargetEncoded` (`unit.c:2396`): the best target for `slot`, encoded, or 0. `mode`
    /// selects the search (0 any, 1 in-range from position, 2 in-range from origin ×2, 4 structures-first).
    public func findBestTargetEncoded(slot: Int, mode: UInt16, in state: inout GameState) -> UInt16 {
        if mode == 4 {
            if let s = findBestTargetStructure(slot: slot, mode: mode, in: state) {
                return state.indexEncode(state.structures[s].o.index, type: .structure)
            }
            guard let u = findBestTargetUnit(slot: slot, mode: mode, in: &state) else { return 0 }
            return state.indexEncode(state.units[u].o.index, type: .unit)
        }

        let target = findBestTargetUnit(slot: slot, mode: mode, in: &state)
        let isDeviator = UnitType(rawValue: Int(state.units[slot].o.type)) == .deviator
        let s = isDeviator ? nil : findBestTargetStructure(slot: slot, mode: mode, in: state)

        if let target, let s {
            let priority = targetUnitPriority(unitSlot: slot, targetSlot: target, in: state)
            if targetStructurePriority(unitSlot: slot, structSlot: s, in: state) >= priority {
                return state.indexEncode(state.structures[s].o.index, type: .structure)
            }
            return state.indexEncode(state.units[target].o.index, type: .unit)
        }
        if let target { return state.indexEncode(state.units[target].o.index, type: .unit) }
        if let s { return state.indexEncode(state.structures[s].o.index, type: .structure) }
        return 0
    }

    /// `Unit_FindBestTargetUnit` (`unit.c:923`). Defaults `originEncoded` to the current tile (mutating),
    /// then scans every unit for the highest priority (optionally distance-gated by `mode`).
    func findBestTargetUnit(slot: Int, mode: UInt16, in state: inout GameState) -> Int? {
        var position = state.units[slot].o.position
        if state.units[slot].originEncoded == 0 {
            state.units[slot].originEncoded = state.indexEncode(position.packed, type: .tile)
        } else {
            position = state.indexGetTile(state.units[slot].originEncoded)
        }

        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return nil }
        var distance = UInt16(UnitInfo[ut].fireDistance) << 8
        if mode == 2 { distance <<= 1 }

        var best: Int? = nil
        var bestPriority: Int16 = 0
        var find = PoolFind()
        while let target = state.unitFind(&find) {
            if mode != 0 && mode != 4 {
                if mode == 1, Tile32.distance(from: state.units[slot].o.position, to: state.units[target].o.position) > distance { continue }
                if mode == 2, Tile32.distance(from: position, to: state.units[target].o.position) > distance { continue }
            }
            let priority = Int16(bitPattern: targetUnitPriority(unitSlot: slot, targetSlot: target, in: state))
            if priority > bestPriority {
                best = target
                bestPriority = priority
            }
        }
        return bestPriority == 0 ? nil : best
    }

    /// `Script_Unit_GetTargetPriority` (op 0x1D, `script/unit.c:96`): the priority `unitSlot` assigns to
    /// the `encoded` target — a unit (`targetUnitPriority`) or structure (`targetStructurePriority`), 0 if
    /// the target no longer resolves.
    func targetPriority(unitSlot: Int, encoded: UInt16, in state: GameState) -> UInt16 {
        if let target = state.indexGetUnit(encoded) {
            return targetUnitPriority(unitSlot: unitSlot, targetSlot: target, in: state)
        }
        if let s = state.indexGetStructure(encoded) {
            return targetStructurePriority(unitSlot: unitSlot, structSlot: s, in: state)
        }
        return 0
    }

    /// `Unit_GetTargetUnitPriority` (`unit.c:743`): the score for `unit` targeting `target` — 0 if it's
    /// self / unallocated / unseen / allied / non-priority / an unreachable air unit / off-map; else the
    /// target's `priorityTarget + priorityBuild` over distance, capped at `0x7D00`.
    func targetUnitPriority(unitSlot: Int, targetSlot: Int, in state: GameState) -> UInt16 {
        if unitSlot == targetSlot { return 0 }
        let target = state.units[targetSlot]
        if !target.o.flags.contains(.allocated) { return 0 }

        let unitHouse = state.unitHouseID(state.units[unitSlot])
        if target.o.seenByHouses & (1 << unitHouse) == 0 { return 0 }
        if house.areAllied(unitHouse, state.unitHouseID(target), playerHouseID: state.playerHouseID) { return 0 }

        guard let uType = UnitType(rawValue: Int(state.units[unitSlot].o.type)),
              let tType = UnitType(rawValue: Int(target.o.type)) else { return 0 }
        let unitInfo = UnitInfo[uType]
        let targetInfo = UnitInfo[tType]

        if !targetInfo.o.flags.contains(.priority) { return 0 }

        if targetInfo.movementType == .winger {
            if !unitInfo.o.flags.contains(.targetAir) { return 0 }
            if target.o.houseID == state.playerHouseID
                && !map.isPositionUnveiled(state.map[Int(target.o.position.packed)], tileIDs: state.tileIDs) { return 0 }
        }

        if !map.isValidPosition(target.o.position.packed, mapScale: state.mapScale) { return 0 }

        let distance = Tile32.distanceRoundedUp(from: state.units[unitSlot].o.position, to: target.o.position)
        if !map.isValidPosition(state.units[unitSlot].o.position.packed, mapScale: state.mapScale) {
            if targetInfo.fireDistance >= distance { return 0 }
        }

        var priority = UInt16(truncatingIfNeeded: Int(targetInfo.o.priorityTarget) + Int(targetInfo.o.priorityBuild))
        if distance != 0 { priority = (priority / distance) + 1 }
        return priority > 0x7D00 ? 0x7D00 : priority
    }

    /// `Unit_FindBestTargetStructure` (`unit.c:2275`): the highest-priority enemy structure (skipping
    /// slabs/walls), optionally distance-gated by `mode`.
    func findBestTargetStructure(slot: Int, mode: UInt16, in state: GameState) -> Int? {
        let position = state.indexGetTile(state.units[slot].originEncoded)
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return nil }
        let distance = UInt16(UnitInfo[ut].fireDistance) << 8

        var best: Int? = nil
        var bestPriority: UInt16 = 0
        var find = PoolFind()
        while let sSlot = state.structureFind(&find) {
            guard let st = StructureType(rawValue: Int(state.structures[sSlot].o.type)) else { continue }
            if st == .slab1x1 || st == .slab2x2 || st == .wall { continue }

            let diff = StructureLayoutInfo[StructureInfo[st].layout].tileDiff
            let curPosition = Tile32.addDiff(state.structures[sSlot].o.position, diff)
            if mode != 0 && mode != 4 {
                if mode == 1 {
                    if Tile32.distance(from: state.units[slot].o.position, to: curPosition) > distance { continue }
                } else {
                    if mode != 2 { continue }
                    if Tile32.distance(from: position, to: curPosition) > distance &* 2 { continue }
                }
            }
            let priority = targetStructurePriority(unitSlot: slot, structSlot: sSlot, in: state)
            if priority >= bestPriority {
                best = sSlot
                bestPriority = priority
            }
        }
        return bestPriority == 0 ? nil : best
    }

    /// `Unit_GetTargetStructurePriority` (`unit.c:2562`): 0 if allied or unseen, else the structure's
    /// `priorityBuild + priorityTarget` over distance, capped at 32000.
    func targetStructurePriority(unitSlot: Int, structSlot: Int, in state: GameState) -> UInt16 {
        let s = state.structures[structSlot]
        let unitHouse = state.unitHouseID(state.units[unitSlot])
        if house.areAllied(unitHouse, s.o.houseID, playerHouseID: state.playerHouseID) { return 0 }
        if s.o.seenByHouses & (1 << unitHouse) == 0 { return 0 }
        guard let st = StructureType(rawValue: Int(s.o.type)) else { return 0 }
        let si = StructureInfo[st]
        var priority = UInt16(truncatingIfNeeded: Int(si.o.priorityBuild) + Int(si.o.priorityTarget))
        let distance = Tile32.distanceRoundedUp(from: state.units[unitSlot].o.position, to: s.o.position)
        if distance != 0 { priority /= distance }
        return min(priority, 32000)
    }
}
