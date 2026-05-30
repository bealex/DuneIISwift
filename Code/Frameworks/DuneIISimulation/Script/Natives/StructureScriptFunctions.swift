import DuneIIContracts
import DuneIIWorld

/// The `Script_Structure_*` natives (op-14 functions in `g_scriptFunctionsStructure`, `src/script/structure.c`),
/// as clean explicit-parameter functions (no stack-poking in the logic — the runner peeks args and passes
/// them in). The structure analog of `UnitScriptFunctions`.
///
/// This first slice ports the natives a structure's *idle loop* and its *death path* reach: state get/set,
/// fog reveal, the two var-4 scrub helpers, and `Explode`/`Destroy`. The combat (FindTarget/RotateTurret/
/// Fire), unit-dispatch (FindUnitByType/unload), and refinery (RefineSpice) natives are deferred to their
/// own slices; until then they clean-halt the script (loud, not invented).
///
/// `Explode`/`Destroy` reach the Simulation-layer `Map_MakeExplosion` + `Unit_Create` + `Unit_SetAction`
/// via the injected `UnitCombat` (which owns the movement/impact layer + the unit `ScriptInfo`).
struct StructureScriptFunctions: Sendable {
    let combat: UnitCombat

    /// `Script_Structure_Unknown0A81` (op 0x02, `:163`): if this structure's var-4 points at a unit that
    /// no longer points back, scrub the unit's var-4 link, then clear the structure's own var-4.
    func unknown0A81(slot: Int, in state: inout GameState) -> UInt16 {
        let structureIndex = state.indexEncode(UInt16(state.structures[slot].o.index), type: .structure)
        let var4 = state.structures[slot].o.script.variables[4]
        if let u = state.indexGetUnit(var4) {
            if structureIndex == state.units[u].o.script.variables[4] { return var4 }
            state.objectScriptVariable4Clear(.unit(u))
        }
        state.objectScriptVariable4Clear(.structure(slot))
        return 0
    }

    /// `Script_Structure_SetState` (op 0x04, `:54`): set the structure's state; `DETECT` (-2) resolves
    /// from the linked unit + countdown (IDLE if unlinked, else READY/BUSY by `countDown`).
    func setState(slot: Int, state requested: Int16, in gameState: inout GameState) -> UInt16 {
        var resolved = requested
        if resolved == StructureState.detect.rawValue {
            if gameState.structures[slot].o.linkedID == 0xFF {
                resolved = StructureState.idle.rawValue
            } else if gameState.structures[slot].countDown == 0 {
                resolved = StructureState.ready.rawValue
            } else {
                resolved = StructureState.busy.rawValue
            }
        }
        gameState.structureSetState(slot, StructureState(rawValue: resolved) ?? .idle)
        return 0
    }

    /// `Script_Structure_Unknown11B9` (op 0x06, `:464`): clear a target unit's var-4 link + its move
    /// order. No-op unless the encoded index is a valid unit.
    func unknown11B9(encoded: UInt16, in state: inout GameState) -> UInt16 {
        guard state.indexIsValid(encoded), Tools.indexType(encoded) == .unit,
              let u = state.indexGetUnit(encoded) else { return 0 }
        state.objectScriptVariable4Clear(.unit(u))
        state.units[u].targetMove = 0
        return 0
    }

    /// `Script_Structure_GetState` (op 0x0D, `:36`): the structure's current state.
    func getState(slot: Int, in state: GameState) -> UInt16 {
        UInt16(bitPattern: state.structures[slot].state.rawValue)
    }

    /// `Script_Structure_RemoveFogAroundTile` (op 0x0F, `:88`): reveal fog around a player structure.
    func removeFogAroundTile(slot: Int, in state: inout GameState) -> UInt16 {
        state.structureRemoveFog(slot)
        return 0
    }

    /// `Script_Structure_Explode` (op 0x16, `:557`): trigger the structure explosion on each of its layout
    /// tiles (`EXPLOSION_STRUCTURE`, damage 0 — the visual collapse; headless this only iterates units in
    /// radius with 0 damage, i.e. a no-op beyond the render seam).
    func explode(slot: Int, in state: inout GameState) -> UInt16 {
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return 0 }
        let layout = StructureLayoutInfo[StructureInfo[st].layout]
        let base = Int(state.structures[slot].o.position.packed)
        for i in 0 ..< Int(layout.tileCount) {
            let tile = Tile32.unpack(UInt16(truncatingIfNeeded: base + Int(layout.tiles[i])))
            combat.movement.mapMakeExplosion(type: 14, position: tile, hitpoints: 0, origin: 0, in: &state)
        }
        return 0
    }

    /// `Script_Structure_Destroy` (op 0x17, `:589`): remove the structure from the map and spawn soldiers
    /// around the rubble. `Structure_Remove` runs first (frees the slot but leaves type/house/position
    /// readable, like OpenDUNE's pool); each layout tile then has a `spawnChance` roll to drop a
    /// `UNIT_SOLDIER` — enemy soldiers attack, player soldiers wander to a nearby tile. The "X is destroyed"
    /// GUI text is a seam (player-only).
    func destroy(slot: Int, in state: inout GameState) -> UInt16 {
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return 0 }
        let si = StructureInfo[st]
        let layout = StructureLayoutInfo[si.layout]
        let base = Int(state.structures[slot].o.position.packed)
        let houseID = state.structures[slot].o.houseID

        state.structureRemove(slot)

        for i in 0 ..< Int(layout.tileCount) {
            let tile = Tile32.unpack(UInt16(truncatingIfNeeded: base + Int(layout.tiles[i])))

            if UInt16(si.o.spawnChance) < UInt16(state.random256.next()) { continue }

            let orientation = Int8(truncatingIfNeeded: Int(state.random256.next()))
            guard let u = combat.unitCreate(index: 0xFFFF, type: UInt8(UnitType.soldier.rawValue),
                                            houseID: houseID, position: tile, orientation: orientation,
                                            in: &state) else { continue }

            let maxHP = UnitInfo[.soldier].o.hitpoints
            state.units[u].o.hitpoints = UInt16(UInt32(maxHP) * UInt32(state.random256.next() & 3) / 256)

            if houseID != state.playerHouseID {
                combat.actions.setAction(slot: u, action: UInt8(ActionType.attack.rawValue),
                                         scriptInfo: combat.movement.scriptInfo, in: &state)
                continue
            }

            combat.actions.setAction(slot: u, action: UInt8(ActionType.move.rawValue),
                                     scriptInfo: combat.movement.scriptInfo, in: &state)
            let dest = Tile32.moveByRandom(state.units[u].o.position, distance: 32, center: true,
                                           rng: &state.random256)
            state.units[u].targetMove = state.indexEncode(dest.packed, type: .tile)
        }
        return 0
    }
}
