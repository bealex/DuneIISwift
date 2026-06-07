import DuneIIContracts
import DuneIIWorld

public extension Simulation {
    /// `Structure_ActivateSpecial` (`structure.c:822`): fire the palace's house special weapon when its
    /// countdown reaches zero. The caller (`gameLoopStructure`) only invokes this for an **AI** palace
    /// (`!human && isAIActive`); the human's launch UI (target selection / saboteur cursor) is a Phase-6 seam,
    /// so a human palace's countdown ticks but never auto-fires. Dispatches on the house's `specialWeapon`:
    ///
    /// - **MISSILE** (Harkonnen/Sardaukar): create the off-map `missileHouse` carrier (one `Random256` for its
    ///   orientation); on success re-arm `countDown`, then — for the AI — target the first non-allied,
    ///   non-slab/wall structure and `Unit_LaunchHouseMissile` it (jitter ±160, free the carrier, spawn the
    ///   death-hand bullet from the palace tile). No target ⇒ discard the carrier (countdown stays armed).
    /// - **FREMEN** (Atreides/Fremen): pick a random map location and spawn 5 Fremen troopers around it (each
    ///   loop draws one discarded `Random256`, a 2-draw `Tile_MoveByRandom(32)`, and an LCG orientation that
    ///   selects `trooper`↔`troopers`), set to HUNT. Re-arm `countDown`.
    /// - **SABOTEUR** (Ordos/Mercenary): find a free tile next to the palace; none ⇒ `countDown = 1` (retry
    ///   next palace tick). Otherwise spawn a saboteur there (one `Random256` orientation), set to SABOTAGE,
    ///   and re-arm `countDown`.
    /// `missileTarget`: for the human launch of a MISSILE weapon, the packed tile the player clicked — the
    /// death-hand fires there (jittered ±160) instead of the AI's "first non-allied structure" scan. `nil`
    /// (the AI auto-fire and the non-missile weapons) keeps the original behaviour.
    mutating func structureActivateSpecial(_ slot: Int, missileTarget: UInt16? = nil) {
        guard
            StructureType(rawValue: Int(state.structures[slot].o.type)) == .palace,
            let combat = unitScript?.combat,
            let actions = unitScript?.actions,
            let scriptInfo = unitScript?.scriptInfo
        else { return }

        let houseID = state.structures[slot].o.houseID
        guard
            let house = HouseID(rawValue: Int(houseID)),
            state.houses[Int(houseID)].flags.contains(.used)
        else { return }

        let countDown = HouseInfo[house].specialCountDown

        switch HouseInfo[house].specialWeapon {
            case 1:  // HOUSE_WEAPON_MISSILE
                let orientation = Int8(truncatingIfNeeded: Int(state.random256.next()))
                guard
                    let carrier = combat.unitCreate(
                        index: Pool.unitIndexInvalid,
                        type: UInt8(UnitType.missileHouse.rawValue),
                        houseID: houseID,
                        position: Tile32(x: 0xFFFF, y: 0xFFFF),
                        orientation: orientation,
                        in: &state
                    )
                else { break }

                state.structures[slot].countDown = countDown
                // An AI launch warns the player ("missile approaching", `Unit_LaunchHouseMissile` feedback 39);
                // the human's own launch is silent here (it enters target-selection in the original).
                if houseID != state.playerHouseID { state.pendingFeedback.append(39) }
                // Human launch: fire the death-hand at the player's chosen tile (`Unit_LaunchHouseMissile`).
                if let missileTarget {
                    let jittered = Tile32.moveByRandom(
                        Tile32.unpack(missileTarget),
                        distance: 160,
                        center: false,
                        rng: &state.random256
                    )
                    let target = state.indexEncode(jittered.packed, type: .tile)
                    let palacePosition = state.structures[slot].o.position
                    state.unitFree(carrier)
                    _ = combat.unitCreateBullet(
                        position: palacePosition,
                        type: UInt8(UnitType.missileHouse.rawValue),
                        houseID: houseID,
                        damage: 0x1F4,
                        target: target,
                        in: &state
                    )
                    return
                }
                // AI: launch at the first non-allied, non-slab/wall structure.
                let housePrim = combat.movement.house
                var find = PoolFind()
                while let sf = state.structureFind(&find) {
                    let tt = state.structures[sf].o.type
                    if tt == UInt8(StructureType.slab1x1.rawValue) || tt == UInt8(StructureType.slab2x2.rawValue)
                            || tt == UInt8(StructureType.wall.rawValue) {
                        continue
                    }
                    if housePrim.areAllied(
                        houseID,
                        state.structures[sf].o.houseID,
                        playerHouseID: state.playerHouseID
                    ) {
                        continue
                    }
                    // `Unit_LaunchHouseMissile` (`unit.c:2581`): jitter the target, free the carrier, fire.
                    let jittered = Tile32.moveByRandom(
                        Tile32.unpack(state.structures[sf].o.position.packed),
                        distance: 160,
                        center: false,
                        rng: &state.random256
                    )
                    let target = state.indexEncode(jittered.packed, type: .tile)
                    let palacePosition = state.structures[slot].o.position
                    state.unitFree(carrier)
                    _ = combat.unitCreateBullet(
                        position: palacePosition,
                        type: UInt8(UnitType.missileHouse.rawValue),
                        houseID: houseID,
                        damage: 0x1F4,
                        target: target,
                        in: &state
                    )
                    return
                }
                state.unitFree(carrier)  // no target — discard the carrier (countdown already re-armed)
                return

            case 2:  // HOUSE_WEAPON_FREMEN
                let location = combat.movement.map.findLocationTile(4, houseID: Pool.houseInvalid, in: &state)
                for _ in 0 ..< 5 {
                    _ = state.random256.next()
                    let position = Tile32.moveByRandom(
                        Tile32.unpack(location),
                        distance: 32,
                        center: true,
                        rng: &state.random256
                    )
                    let orientation = state.randomLCG.range(0, 3)
                    let unitType: UnitType = orientation == 1 ? .trooper : .troopers
                    // Bypass the per-house unit cap while creating the Fremen — the Fremen house (3) isn't a
                    // scenario house, so its `unitCountMax` is 0 and `Unit_Allocate` would otherwise refuse
                    // every foot soldier. OpenDUNE brackets the create with `g_validateStrictIfZero++/--`.
                    state.validateStrictIfZero &+= 1
                    let created = combat.unitCreate(
                        index: Pool.unitIndexInvalid,
                        type: UInt8(unitType.rawValue),
                        houseID: UInt8(HouseID.fremen.rawValue),
                        position: position,
                        orientation: Int8(truncatingIfNeeded: Int(orientation)),
                        in: &state
                    )
                    state.validateStrictIfZero &-= 1
                    guard let u = created else { continue }

                    actions.setAction(
                        slot: u,
                        action: UInt8(ActionType.hunt.rawValue),
                        scriptInfo: scriptInfo,
                        in: &state
                    )
                }
                state.structures[slot].countDown = countDown

            case 3:  // HOUSE_WEAPON_SABOTEUR
                guard let functions = structureScript?.structure else { return }

                let position = functions.findFreePosition(slot: slot, checkForSpice: false, in: &state)
                if position == 0 { state.structures[slot].countDown = 1; return }
                let orientation = Int8(truncatingIfNeeded: Int(state.random256.next()))
                guard
                    let u = combat.unitCreate(
                        index: Pool.unitIndexInvalid,
                        type: UInt8(UnitType.saboteur.rawValue),
                        houseID: houseID,
                        position: Tile32.unpack(position),
                        orientation: orientation,
                        in: &state
                    )
                else { return }

                actions.setAction(
                    slot: u,
                    action: UInt8(ActionType.sabotage.rawValue),
                    scriptInfo: scriptInfo,
                    in: &state
                )
                state.structures[slot].countDown = countDown

            default:
                break
        }
        // SEAM (player): GUI_Widget_ActionPanel_Draw(true) for the player's palace.
    }

    /// Apply a palace super-weapon player `Command`. The launch is gated to a **ready** (`countDown == 0`),
    /// used, player-owned palace, so a stale UI click can't fire early or fire an enemy/non-palace. Returns
    /// `true` if `command` was a super-weapon command (consumed here); `false` ⇒ the caller routes it through
    /// `UnitOrders`. The human's death-hand carries its clicked target; Fremen/saboteur are no-target.
    mutating func applyPalaceCommand(_ command: Command) -> Bool {
        switch command {
            case let .activateSuperWeapon(structure):
                if palaceReadyForPlayer(Int(structure)) { structureActivateSpecial(Int(structure)) }
                return true
            case let .launchHouseMissile(structure, tile):
                if palaceReadyForPlayer(Int(structure)) {
                    structureActivateSpecial(Int(structure), missileTarget: tile)
                }
                return true
            default:
                return false
        }
    }

    private func palaceReadyForPlayer(_ slot: Int) -> Bool {
        guard slot >= 0, slot < state.structures.count else { return false }

        let s = state.structures[slot]
        return s.o.flags.contains(.used)
            && s.o.type == UInt8(StructureType.palace.rawValue)
            && s.o.houseID == state.playerHouseID
            && s.countDown == 0
    }
}
