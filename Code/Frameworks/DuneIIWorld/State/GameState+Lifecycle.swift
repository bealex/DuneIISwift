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
}
