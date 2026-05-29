import DuneIIContracts

/// Object/reference lifecycle bookkeeping: the state mutations that run when an object is linked,
/// unlinked, or removed. Faithful ports of OpenDUNE's `src/object.c`, `src/structure.c`, and the
/// reference-clearing part of `src/unit.c`. These are mechanical pool/map state changes (no decision
/// logic), so they live on `GameState` alongside the pools — the Simulation-layer lifecycle primitives
/// (`Unit_Remove`, `Unit_Deviate`, …) call them.
public extension GameState {
    /// `Structure_GetLinkedUnit` (`structure.c`): the slot of the unit linked to a structure, or `nil`.
    func structureGetLinkedUnit(_ index: Int) -> Int? {
        let linked = structures[index].o.linkedID
        return linked == 0xFF ? nil : Int(linked)
    }

    /// `Structure_SetState` (`structure.c`): set a structure's state and re-stamp it onto the map
    /// (which restarts the state's animation).
    mutating func structureSetState(_ index: Int, _ state: StructureState) {
        structures[index].state = state
        structureUpdateMap(index)
    }

    /// `Object_Script_Variable4_Set` (`object.c`): store an encoded index in script variable 4. For a
    /// structure whose BUSY lights mean "a unit is incoming" (`busyStateIsIncoming`) and that has no
    /// linked unit, this also flips its state — IDLE when clearing (`encoded == 0`), BUSY when setting.
    mutating func objectScriptVariable4Set(_ ref: ObjectRef, _ encoded: UInt16) {
        switch ref {
            case .unit(let i):
                units[i].o.script.variables[4] = encoded
            case .structure(let i):
                structures[i].o.script.variables[4] = encoded
                guard let type = StructureType(rawValue: Int(structures[i].o.type)),
                      StructureInfo[type].o.flags.contains(.busyStateIsIncoming),
                      structureGetLinkedUnit(i) == nil else { return }
                structureSetState(i, encoded == 0 ? .idle : .busy)
        }
    }

    /// `Object_Script_Variable4_Clear` (`object.c`): clear the two-way link script variable 4 forms —
    /// zero it on this object and on the object it points at.
    mutating func objectScriptVariable4Clear(_ ref: ObjectRef) {
        let encoded = object(ref).script.variables[4]
        if encoded == 0 { return }
        let other = indexGetObject(encoded)
        objectScriptVariable4Set(ref, 0)
        if let other { objectScriptVariable4Set(other, 0) }
    }

    /// `Unit_RemoveFromTeam` (`unit.c`): drop a unit from its team, returning the team's resulting free
    /// slots (`maxMembers - members`); a unit with no team is a no-op returning 0.
    @discardableResult
    mutating func unitRemoveFromTeam(_ unitSlot: Int) -> UInt16 {
        let team = units[unitSlot].team
        if team == 0 { return 0 }
        let t = Int(team) - 1
        teams[t].members &-= 1
        units[unitSlot].team = 0
        return teams[t].maxMembers &- teams[t].members
    }

    /// `Unit_UntargetMe` (`unit.c`): scrub every reference to a unit before it is removed — clear its
    /// own two-way link, then zero any `targetMove`/`targetAttack`/script-var-4 on other units, the
    /// `variables[2]` of turret structures, the unit's team membership, and any team `target` pointing
    /// at it.
    mutating func unitUntargetMe(_ unitSlot: Int) {
        let encoded = indexEncode(units[unitSlot].o.index, type: .unit)

        objectScriptVariable4Clear(.unit(unitSlot))

        var unitIter = PoolFind()
        while let s = unitFind(&unitIter) {
            if units[s].targetMove == encoded { units[s].targetMove = 0 }
            if units[s].targetAttack == encoded { units[s].targetAttack = 0 }
            if units[s].o.script.variables[4] == encoded { objectScriptVariable4Clear(.unit(s)) }
        }

        var structIter = PoolFind()
        while let s = structureFind(&structIter) {
            let type = Int(structures[s].o.type)
            if type != StructureType.turret.rawValue && type != StructureType.rocketTurret.rawValue {
                continue
            }
            if structures[s].o.script.variables[2] == encoded { structures[s].o.script.variables[2] = 0 }
        }

        unitRemoveFromTeam(unitSlot)

        var teamIter = PoolFind()
        while let t = teamFind(&teamIter) {
            if teams[t].target == encoded { teams[t].target = 0 }
        }
    }

    // MARK: - Map occupancy + visibility counts

    /// `Unit_RemoveFromTile` (`unit.c`): clear a map tile's unit occupancy, but only if the tile
    /// actually holds this unit and either it isn't the unit's current destination or the unit is
    /// "big" (`bulletIsBig`). The trailing `Map_MarkTileDirty`/`Map_Update` are render seams, skipped.
    mutating func unitRemoveFromTile(_ slot: Int, _ packed: UInt16) {
        guard map[Int(packed)].hasUnit, unitGetByPackedTile(packed) == slot else { return }
        let u = units[slot]
        if packed != u.currentDestination.packed || u.o.flags.contains(.bulletIsBig) {
            map[Int(packed)].index = 0
            map[Int(packed)].hasUnit = false
        }
    }

    /// `Unit_HouseUnitCount_Remove` (`unit.c`): a unit leaving the map drops out of every house's
    /// "units I can see" tally — for each house that had seen it, decrement that house's allied- or
    /// enemy-unit count and clear the seen bit; then (1.07-enhanced) zero `seenByHouses`.
    mutating func unitHouseUnitCountRemove(_ slot: Int) {
        if units[slot].o.seenByHouses == 0 { return }
        let unitHouse = unitHouseID(units[slot])

        var find = PoolFind()
        while let h = houseFind(&find) {
            let bit = UInt8(1 << houses[h].index)
            if units[slot].o.seenByHouses & bit == 0 { continue }
            if !House.areAllied(houses[h].index, unitHouse, playerHouseID: playerHouseID) {
                houses[h].unitCountEnemy &-= 1
            } else {
                houses[h].unitCountAllied &-= 1
            }
            units[slot].o.seenByHouses &= ~bit
        }
        units[slot].o.seenByHouses = 0   // ENHANCEMENT (g_dune2_enhanced), which we pin true here
    }

    /// `Unit_HouseUnitCount_Add` (`unit.c`): record that `houseID` now sees this unit — bump its
    /// allied/enemy tally on first sight and flip the AI awake when an enemy is spotted.
    ///
    /// **Seams (deferred):** the player-alert block (`houseID == player && selectionType != MENTAT`:
    /// sandworm/attack sound feedback, the GUI hint, `g_musicInBattle`, the suppression timers, and the
    /// team's `variables[4]`) is the audio/GUI notification subsystem we don't model headlessly; and the
    /// ambush→`Unit_SetAction(HUNT)` reaction needs the EMC script VM. Both are marked below.
    mutating func unitHouseUnitCountAdd(_ slot: Int, houseID: UInt8) {
        guard let ut = UnitType(rawValue: Int(units[slot].o.type)) else { return }
        let ui = UnitInfo[ut]
        var houseIDBit = UInt8(1 << houseID)
        if houseID == UInt8(HouseID.atreides.rawValue) && ut != .sandworm {
            houseIDBit |= UInt8(1 << HouseID.fremen.rawValue)
        }

        if units[slot].o.seenByHouses & houseIDBit != 0 && houses[Int(houseID)].flags.contains(.isAIActive) {
            units[slot].o.seenByHouses |= houseIDBit
            return
        }

        if !ui.flags.contains(.isNormalUnit) && ut != .sandworm { return }

        let unitHouse = unitHouseID(units[slot])
        let allied = House.areAllied(houseID, unitHouse, playerHouseID: playerHouseID)
        if units[slot].o.seenByHouses & houseIDBit == 0 {
            if allied { houses[Int(houseID)].unitCountAllied &+= 1 }
            else { houses[Int(houseID)].unitCountEnemy &+= 1 }
        }

        if ui.movementType != .winger && !allied {
            houses[Int(houseID)].flags.insert(.isAIActive)
            houses[Int(unitHouse)].flags.insert(.isAIActive)
        }

        // SEAM: player-alert block (audio/GUI/music + suppression timers + team var4) — needs the audio
        // + GUI seams and `g_selectionType`, which we don't model headlessly. (unit.c:Unit_HouseUnitCount_Add)
        // SEAM: ambush → Unit_SetAction(HUNT) reaction — needs the EMC script VM (Tier-F #19).

        if unitHouse == UInt8(HouseID.fremen.rawValue) && playerHouseID == UInt8(HouseID.atreides.rawValue)
            || units[slot].o.houseID == playerHouseID {
            units[slot].o.seenByHouses = 0xFF
        } else {
            units[slot].o.seenByHouses |= houseIDBit
        }
    }

    /// `Unit_UpdateMap` (`unit.c`): reconcile a unit with the map after it moves / is placed / is
    /// removed. `type`: 0 = remove, 1 = place, 2 = redraw. Here we port the **headless game-state**
    /// effects — the per-house visibility counts and the tile occupancy (`Unit_RemoveFromTile` for
    /// type 0, the explicit claim for type 1). The render dirty-marking (`Map_Update`, the dirty-unit
    /// counters), the air-unit `Map_UpdateAround` redraw, and the fog-unveil radius
    /// (`Tile_RemoveFogInRadius` / `Map_UnveilTile`) are render/fog seams left to the renderer + the
    /// pending fog port; they don't affect the deterministic simulation here.
    mutating func unitUpdateMap(_ type: Int, _ slot: Int) {
        let u = units[slot]
        if u.o.flags.contains(.isNotOnMap) || !u.o.flags.contains(.used) { return }
        guard let ut = UnitType(rawValue: Int(u.o.type)) else { return }
        let ui = UnitInfo[ut]

        // Air units carry no ground-tile occupancy; their UpdateMap is purely a render redraw. (SEAM)
        if ui.movementType == .winger { return }

        let packed = u.o.position.packed
        if map[Int(packed)].isUnveiled || u.o.houseID == playerHouseID {
            unitHouseUnitCountAdd(slot, houseID: playerHouseID)
        } else {
            unitHouseUnitCountRemove(slot)
        }

        if type == 1 {
            // SEAM: Tile_RemoveFogInRadius — the fog-unveil radius port is still pending.
            let occupied = map[Int(packed)].hasUnit || map[Int(packed)].hasStructure
            if !occupied {
                map[Int(packed)].index = UInt8(truncatingIfNeeded: slot + 1)
                map[Int(packed)].hasUnit = true
            }
        }

        if type == 0 {
            unitRemoveFromTile(slot, packed)
            if ut == .harvester {   // the only 2×1 unit — also clear its trailing tiles
                unitRemoveFromTile(slot, units[slot].targetPreLast.packed)
                unitRemoveFromTile(slot, units[slot].targetLast.packed)
            }
        }
    }

    // MARK: - Unit helpers

    /// `Unit_FindClosestRefinery` (`unit.c`): for a harvester, point `originEncoded` at the nearest
    /// same-house refinery — preferring a BUSY one, else any — and return 1 if the unit already had an
    /// origin (0 otherwise). For a non-harvester it just stamps the current tile as the origin. Mutates
    /// `units[slot].originEncoded`.
    @discardableResult
    mutating func unitFindClosestRefinery(_ slot: Int) -> UInt16 {
        let res: UInt16 = units[slot].originEncoded == 0 ? 0 : 1

        if units[slot].o.type != UInt8(UnitType.harvester.rawValue) {
            units[slot].originEncoded = indexEncode(units[slot].o.position.packed, type: .tile)
            return res
        }

        let houseID = unitHouseID(units[slot])
        let refinery = UInt16(StructureType.refinery.rawValue)
        let position = units[slot].o.position

        func nearest(busyOnly: Bool) -> Int? {
            var best: Int? = nil
            var mind: UInt16 = 0
            var find = PoolFind(houseID: houseID, type: refinery)
            while let s = structureFind(&find) {
                if busyOnly && structures[s].state != .busy { continue }
                let d = Tile32.distance(from: position, to: structures[s].o.position)
                if mind != 0 && d >= mind { continue }
                mind = d
                best = s
            }
            return best
        }

        let best = nearest(busyOnly: true) ?? nearest(busyOnly: false)
        if let best { units[slot].originEncoded = indexEncode(structures[best].o.index, type: .structure) }
        return res
    }

    // MARK: - Removal

    /// `Unit_Remove` (`unit.c`): tear a unit down — scrub references, drop it off the map, clear its
    /// visibility tally, reset its script, and free the pool slot. `Unit_Select(NULL)` (deselect) is a
    /// render seam.
    mutating func unitRemove(_ slot: Int) {
        units[slot].o.flags.insert(.allocated)
        unitUntargetMe(slot)
        // SEAM: if this unit was the selected one, Unit_Select(NULL) — a render/UI concern.
        units[slot].o.flags.insert(.bulletIsBig)
        unitUpdateMap(0, slot)
        unitHouseUnitCountRemove(slot)
        units[slot].o.script.reset()
        unitFree(slot)
    }
}
