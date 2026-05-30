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

    /// `Script_Structure_FindTargetUnit` (op 0x08, `:303`): scan the unit pool for a non-allied unit within
    /// `range` (256/tile; ornithopters use `range*3`) that the structure's house can see, encoded `IT_UNIT`
    /// (0 if none). **1.07 faithfulness:** `distanceCurrent` is never updated (the original swapped
    /// assignment is a no-op), so the closest-unit logic is inert — this returns the *last* matching unit in
    /// pool order, not the nearest. The distance is measured from the structure's top-left (un-centred) tile.
    func findTargetUnit(slot: Int, range: UInt16, in state: inout GameState) -> UInt16 {
        let sHouse = state.structures[slot].o.houseID
        let position = state.structures[slot].o.position
        let ornithopter = UInt8(UnitType.ornithopter.rawValue)
        var found: Int?
        var find = PoolFind()
        while let u = state.unitFind(&find) {
            if House.areAllied(sHouse, state.unitHouseID(state.units[u]), playerHouseID: state.playerHouseID) { continue }
            let uType = state.units[u].o.type
            if uType != ornithopter, state.units[u].o.seenByHouses & (1 << sHouse) == 0 { continue }
            let distance = Tile32.distance(from: state.units[u].o.position, to: position)
            // 1.07: `distance >= distanceCurrent(32000)` never fires; the range gate uses `>=`.
            if distance >= (uType == ornithopter ? range &* 3 : range) { continue }
            found = u
        }
        guard let f = found else { return 0 }   // IT_NONE
        return state.indexEncode(UInt16(state.units[f].o.index), type: .unit)
    }

    /// `Script_Structure_RotateTurret` (op 0x09, `:375`): step the turret one notch toward `encoded`'s tile;
    /// 0 = already aimed, 1 = still rotating. Reads/writes the turret's `groundTileID` (base sprite +
    /// rotation 0–7). Needs an `iconMap` to resolve the base sprite; without one it reports "rotating". The
    /// `Map_Update` render redraw is a seam.
    func rotateTurret(slot: Int, encoded: UInt16, in state: inout GameState) -> UInt16 {
        if encoded == 0 { return 0 }
        guard let iconMap = state.iconMap,
              let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return 1 }
        let group = (st == .rocketTurret) ? 24 : 23   // ICM_ICONGROUP_BASE_ROCKET / DEFENSE_TURRET
        guard let baseTileID = iconMap.tileID(group: group, offset: 2) else { return 1 }

        let packed = Int(state.structures[slot].o.position.packed)
        var rotation = Int(state.map[packed].groundTileID) - baseTileID
        if rotation < 0 || rotation > 7 { return 1 }

        let lookAt = state.indexGetTile(encoded)
        let needed = Int(Orientation.to8(UInt8(bitPattern: Tile32.direction(from: state.structures[slot].o.position, to: lookAt))))
        if needed == rotation { return 0 }

        var diff = needed - rotation
        if diff < 0 { diff += 8 }
        rotation += (diff < 4) ? 1 : -1
        rotation &= 0x7

        state.map[packed].groundTileID = UInt16(truncatingIfNeeded: baseTileID + rotation)
        state.structures[slot].rotationSpriteDiff = UInt16(rotation)
        state.mapDirty = true
        return 1
    }

    /// `Script_Structure_GetDirection` (op 0x0A, `:440`): the 8-orientation (×32) from the structure to
    /// `encoded`'s tile, or the turret's current facing (`rotationSpriteDiff` ×32) if the index is invalid.
    func getDirection(slot: Int, encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return state.structures[slot].rotationSpriteDiff << 5 }
        let tile = state.indexGetTile(encoded)
        let o8 = Orientation.to8(UInt8(bitPattern: Tile32.direction(from: state.structures[slot].o.position, to: tile)))
        return UInt16(o8) << 5
    }

    /// `Script_Structure_Fire` (op 0x0B, `:513`): fire the turret's bullet/missile at `variables[2]` via the
    /// already-ported `Unit_CreateBullet`. A rocket turret ≥ 0x300 from its target launches a missile
    /// (damage 30, launcher fire delay); otherwise a bullet (damage 20, tank fire delay). Returns the
    /// speed-adjusted ticks until the next shot (0 if no target or the spawn failed).
    func fire(slot: Int, in state: inout GameState) -> UInt16 {
        let target = state.structures[slot].o.script.variables[2]
        if target == 0 { return 0 }
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return 0 }

        let type: UInt8, damage: UInt16, fireDelayBase: UInt16
        if st == .rocketTurret,
           Tile32.distance(from: state.indexGetTile(target), to: state.structures[slot].o.position) >= 0x300 {
            type = UInt8(UnitType.missileTurret.rawValue); damage = 30; fireDelayBase = UnitInfo[.launcher].fireDelay
        } else {
            type = UInt8(UnitType.bullet.rawValue); damage = 20; fireDelayBase = UnitInfo[.tank].fireDelay
        }
        let fireDelay = Tools.adjustToGameSpeed(normal: fireDelayBase, minimum: 1, maximum: 0xFFFF,
                                                inverseSpeed: true, gameSpeed: state.gameSpeed)

        var position = state.structures[slot].o.position
        position.x = position.x &+ 0x80
        position.y = position.y &+ 0x80
        guard let bullet = combat.unitCreateBullet(position: position, type: type,
                                                   houseID: state.structures[slot].o.houseID,
                                                   damage: damage, target: target, in: &state) else { return 0 }
        state.units[bullet].originEncoded = state.indexEncode(UInt16(state.structures[slot].o.index), type: .structure)
        return fireDelay
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
