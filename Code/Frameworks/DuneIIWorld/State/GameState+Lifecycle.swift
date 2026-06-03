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
                guard
                    let type = StructureType(rawValue: Int(structures[i].o.type)),
                    StructureInfo[type].o.flags.contains(.busyStateIsIncoming),
                    structureGetLinkedUnit(i) == nil
                else { return }
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

    /// `Object_Script_Variable4_Link` (`object.c`): form the two-way script-variable-4 link between two
    /// encoded objects (clearing any mismatched prior links first), but only if `from`'s slot is free.
    mutating func objectScriptVariable4Link(_ encodedFrom: UInt16, _ encodedTo: UInt16) {
        guard
            indexIsValid(encodedFrom),
            indexIsValid(encodedTo),
            let from = indexGetObject(encodedFrom),
            let to = indexGetObject(encodedTo)
        else { return }
        if object(from).script.variables[4] != object(to).script.variables[4] {
            objectScriptVariable4Clear(from)
            objectScriptVariable4Clear(to)
        }
        if object(from).script.variables[4] != 0 { return }
        objectScriptVariable4Set(from, encodedTo)
        objectScriptVariable4Set(to, encodedFrom)
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

    /// `Unit_AddToTeam` (`unit.c:540`): add a unit to team `teamSlot` (its `team` becomes `index+1`,
    /// `members++`), returning the team's resulting free slots (`maxMembers - members`).
    @discardableResult
    mutating func unitAddToTeam(_ unitSlot: Int, team teamSlot: Int) -> UInt16 {
        units[unitSlot].team = UInt8(teamSlot) &+ 1
        teams[teamSlot].members &+= 1
        return teams[teamSlot].maxMembers &- teams[teamSlot].members
    }

    /// `Map_IsValidPosition` (`map.c`): is `packed` on the playable rectangle for the current `mapScale`?
    /// (`packed & 0xC000 == 0` and within the scale's `MapInfo` bounds.) The World-side counterpart of
    /// `MapPrimitives.isValidPosition`, for the World primitives that need a validity check.
    func mapIsValidPosition(_ packed: UInt16) -> Bool {
        if packed & 0xC000 != 0 { return false }
        let x = UInt16(Tile32.packedX(packed)), y = UInt16(Tile32.packedY(packed))
        let info = MapInfo.scales[Int(mapScale)]
        return info.minX <= x && x < info.minX + info.sizeX
            && info.minY <= y && y < info.minY + info.sizeY
    }

    /// `Tile_GetTileInDirectionOf` (`tile.c:155`): pick a random valid tile roughly in the direction from
    /// `packedFrom` toward `packedTo`, at `min(distance, 20)` tiles out, jittered ±(31…94) about the
    /// direction. Returns 0 if either tile is unset or they are within 10 tiles. Draws two `Random256`
    /// values per attempt; OpenDUNE retries forever until a valid tile, we cap the retries (the cap is not
    /// reached in practice) and return 0 as a headless-safety fallback.
    mutating func tileGetTileInDirectionOf(from packedFrom: UInt16, to packedTo: UInt16) -> UInt16 {
        if packedFrom == 0 || packedTo == 0 { return 0 }
        let distance = Tile32.distancePacked(packedFrom, packedTo)
        let direction = Int16(Tile32.directionPacked(packedTo, packedFrom))
        if distance <= 10 { return 0 }

        for _ in 0 ..< 1024 {
            var dir = Int16(31) + Int16(random256.next() & 0x3F)
            if random256.next() & 1 != 0 { dir = -dir }
            let out = UInt16(min(distance, 20)) << 8
            let position = Tile32.moveByDirection(Tile32.unpack(packedTo), orientation: direction + dir, distance: out)
            let packed = position.packed
            if mapIsValidPosition(packed) { return packed }
        }
        return 0
    }

    /// `Unit_RemovePlayer` (`unit.c:2440`): when a *player-owned* allocated unit is lost, mark it
    /// unallocated and drop it from its team. The deselect / selection-type / active-action cleanup
    /// (`Unit_Select`, `GUI_ChangeSelectionType`) is a render/UI seam. Returns true if it acted.
    @discardableResult
    mutating func unitRemovePlayer(_ slot: Int) -> Bool {
        if unitHouseID(units[slot]) != playerHouseID { return false }
        if !units[slot].o.flags.contains(.allocated) { return false }
        units[slot].o.flags.remove(.allocated)
        unitRemoveFromTeam(slot)
        // SEAM: if this was the selected unit — deselect + selection-type/active-action reset (UI).
        return true
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

    /// `Structure_UntargetMe` (`structure.c`): scrub every reference to a structure before it is destroyed
    /// — clear its own two-way script-var-4 link, then zero any unit `targetMove`/`targetAttack`/script-
    /// var-4 and any team `target` pointing at it. (The unit `Unit_UntargetMe` analog, minus the turret +
    /// team-membership bits, which only apply to a unit.)
    mutating func structureUntargetMe(_ structureSlot: Int) {
        let encoded = indexEncode(structures[structureSlot].o.index, type: .structure)

        objectScriptVariable4Clear(.structure(structureSlot))

        var unitIter = PoolFind()
        while let u = unitFind(&unitIter) {
            if units[u].targetMove == encoded { units[u].targetMove = 0 }
            if units[u].targetAttack == encoded { units[u].targetAttack = 0 }
            if units[u].o.script.variables[4] == encoded { objectScriptVariable4Clear(.unit(u)) }
        }

        var teamIter = PoolFind()
        while let t = teamFind(&teamIter) {
            if teams[t].target == encoded { teams[t].target = 0 }
        }
    }

    /// `Structure_Remove` (`structure.c:1305`): tear a structure off the map and free its slot — clear the
    /// `hasStructure` occupancy on each of its layout tiles, free the slot (`Structure_Free`), and scrub
    /// references (`Structure_UntargetMe`), and record the loss in the house's `aiStructureRebuild` queue so
    /// the AI can rebuild it. The destruction animation (`Animation_Start` / `Animation_Stop_ByTile`) is a
    /// render seam.
    mutating func structureRemove(_ slot: Int) {
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return }
        let layout = StructureLayoutInfo[StructureInfo[st].layout]
        let packed = Int(structures[slot].o.position.packed)

        for i in 0 ..< Int(layout.tileCount) {
            let curPacked = packed + Int(layout.tiles[i])
            animationStopByTile(UInt16(truncatingIfNeeded: curPacked))  // stop the structure's idle anim
            if curPacked >= 0, curPacked < map.count { map[curPacked].hasStructure = false }
        }
        // Start the destruction/collapse animation (`Structure_Remove`, `structure.c:1305`:
        // `Animation_Start(g_table_animation_structure[0], …)`). It overwrites the building's stamped
        // ground tiles with the rubble frames and `abort`s back to the base landscape — so the building
        // disappears. Without it the building's `groundTileID` stays on the map and it never goes away.
        // (Headless/golden runs don't tick animations, exactly as the oracle's parity harness doesn't —
        // so the animation is queued but inert there, matching the oracle; the visual apps play it.)
        let si = StructureInfo[st]
        animationStart(
            tableIndex: 0,
            tile: structures[slot].o.position,
            tileLayout: UInt16(si.layout.rawValue),
            houseID: structures[slot].o.houseID,
            iconGroup: UInt8(truncatingIfNeeded: Int(si.iconGroup))
        )
        mapDirty = true

        // Remember the lost structure's type + position in the house's AI rebuild queue (`structure.c:1336`),
        // first free of 5 slots. The AI construction-yard maintenance pass (`aiStructureMaintenance`) rebuilds
        // it and re-places it here. RNG-free bookkeeping.
        let houseID = Int(structures[slot].o.houseID)
        let lostType = UInt16(structures[slot].o.type)
        for i in 0 ..< 5 where houses[houseID].aiStructureRebuild[i][0] == 0 {
            houses[houseID].aiStructureRebuild[i] = [ lostType, UInt16(truncatingIfNeeded: packed) ]
            break
        }

        structureFree(slot)
        structureUntargetMe(slot)
    }

    /// `Structure_Destroy` (`structure.c:979`): begin a structure's destruction — mark it destroyed
    /// (`variables[0] = 1`, no longer `allocated`), reset its script, remove any units it has linked (or
    /// destroy a construction yard's linked structure), and apply the House credit penalty + windtrap
    /// decrement. It does **not** free the slot: OpenDUNE loads the structure's death script, which plays
    /// the collapse animation and then calls `Structure_Remove`. We **seam** that `Script_Load` (it needs
    /// the structure `ScriptInfo` from `BUILD.EMC`, a Simulation concern) + the audio — so the destroyed
    /// structure stays unallocated-but-unremoved here until the script layer drives `structureRemove`.
    /// The `g_campaignID > 7` extra-refund bonus is pinned off (campaigns aren't modeled).
    mutating func structureDestroy(_ slot: Int) {
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return }
        let si = StructureInfo[st]

        structures[slot].o.script.variables[0] = 1
        structures[slot].o.flags.remove(.allocated)
        structures[slot].o.flags.remove(.repairing)
        structures[slot].o.script.delay = 0
        structures[slot].o.script.reset()  // Script_Reset
        // SEAM: Script_Load(structure death script) — needs BUILD.EMC + the structure ScriptInfo.
        emitSound(44, at: structures[slot].o.position)  // Voice_PlayAtTile(44) → voiceMapping → CRUMBLE collapse cue

        let linkedID = structures[slot].o.linkedID
        if linkedID != 0xFF {
            if st == .constructionYard {
                structureDestroy(Int(linkedID))
                structures[slot].o.linkedID = 0xFF
            } else {
                var lid = linkedID
                while lid != 0xFF {
                    let next = units[Int(lid)].o.linkedID
                    unitRemove(Int(lid))
                    lid = next
                }
            }
        }

        // Credit penalty: lose a share proportional to this structure's storage; an *enemy* structure also
        // refunds its build cost to its owner (the player's does not).
        let hID = Int(structures[slot].o.houseID)
        let credits = houses[hID].credits
        let loss: UInt16
        if houses[hID].creditsStorage == 0 {
            loss = credits
        } else {
            let f = UInt32(credits) * 256 / UInt32(houses[hID].creditsStorage) * UInt32(si.creditsStorage) / 256
            loss = UInt16(min(UInt32(credits), f))
        }
        houses[hID].credits = credits &- loss
        if structures[slot].o.houseID != playerHouseID { houses[hID].credits &+= si.o.buildCredits }

        if st == .windtrap { houses[hID].windtrapCount &-= 1 }
    }

    /// `Structure_Damage` (`structure.c:1037`): apply `damage` to a structure, returning true iff it was
    /// destroyed. A no-op for 0 damage or an already-destroying structure. On reaching 0 HP it begins
    /// destruction (`Structure_Destroy` + `Structure_UntargetMe`); the score tally + sound are seams.
    /// A survivor with `range != 0` would spawn a surrounding `Map_MakeExplosion(IMPACT_LARGE)` — that is
    /// a Simulation-layer call (`UnitImpact`), so it is a seam here; the bullet/impact path passes range 0.
    @discardableResult
    mutating func structureDamage(_ slot: Int, damage: UInt16, range: UInt16) -> Bool {
        if damage == 0 { return false }
        if structures[slot].o.script.variables[0] == 1 { return false }

        if structures[slot].o.hitpoints >= damage {
            structures[slot].o.hitpoints &-= damage
        } else {
            structures[slot].o.hitpoints = 0
        }

        if structures[slot].o.hitpoints == 0 {
            // Destroy tally (`structure.c:1055`): a friendly loss subtracts, an enemy loss adds, by
            // `max(buildCredits/100, 1)`.
            if let st = StructureType(rawValue: Int(structures[slot].o.type)) {
                let score = max(StructureInfo[st].o.buildCredits / 100, 1)
                if House.areAllied(playerHouseID, structures[slot].o.houseID, playerHouseID: playerHouseID) {
                    scenario.destroyedAllied &+= 1; scenario.score &-= score
                } else {
                    scenario.destroyedEnemy &+= 1; scenario.score &+= score
                }
            }
            structureDestroy(slot)
            // The spoken "structure destroyed" announcement (`structure.c:1071`): the player's own loss says
            // its house name (22/23/24 for Harkonnen/Atreides/Ordos; no cue for other houses), an enemy's
            // says the generic "enemy structure destroyed" (21). Routed through the global feedback queue.
            if structures[slot].o.houseID == playerHouseID {
                switch playerHouseID { case 0: pendingFeedback.append(22);  case 1: pendingFeedback.append(23)
                    case 2: pendingFeedback.append(24);
                    default: break
                }
            } else {
                pendingFeedback.append(21)
            }
            structureUntargetMe(slot)
            return true
        }

        if range == 0 { return false }
        // SEAM: Map_MakeExplosion(EXPLOSION_IMPACT_LARGE, structure tile, 0, 0) — Simulation layer.
        return false
    }

    /// `Structure_HouseUnderAttack` (`structure.c:1933`): the "your base is under attack" alert, raised when
    /// an explosion lands on one of `houseID`'s structures (`Map_MakeExplosion`, `map.c:500`) — so it fires on
    /// real combat impact only, never on degradation, power-shortfall HP clamping, or partial-slab placement.
    /// For the human player (the single `flags.human` house ≡ `playerHouseID`), it raises the global feedback
    /// (`Sound_Output_Feedback(48)` — voice + viewport message) at most once per `timerStructureAttack` window
    /// (set to 8 here, ticked down in the house loop). For an AI house it flips the one-shot `doneFullScaleAttack`
    /// flag; the original's `g_dune2_enhanced`-only counter-attack loop (foot a carryall search that does nothing
    /// un-enhanced) is omitted — un-enhanced parity behaviour.
    mutating func structureHouseUnderAttack(_ houseID: UInt8) {
        guard houseID != 0xFF else { return }
        let h = Int(houseID)
        if houseID != playerHouseID, houses[h].flags.contains(.doneFullScaleAttack) { return }
        houses[h].flags.insert(.doneFullScaleAttack)

        // The player house is the human one in single-player; gate on `playerHouseID` (RNG-free, so the
        // golden stream is untouched whether or not `flags.human` was set at load).
        guard houseID == playerHouseID else { return }
        if houses[h].timerStructureAttack != 0 { return }
        pendingFeedback.append(48)  // Sound_Output_Feedback(48) — "your base is under attack"
        houses[h].timerStructureAttack = 8
    }

    /// `Unit_Hide` (`unit.c:1083`): take a unit off the map + out of play without freeing it — used when it
    /// enters a structure. Clears its tile occupancy (the `bulletIsBig` toggle keeps a 2-tile bullet's
    /// footprint clearing), resets its script, scrubs references, flags it off-map, and drops it from the
    /// per-house visibility counts.
    mutating func unitHide(_ slot: Int) {
        units[slot].o.flags.insert(.bulletIsBig)
        unitUpdateMap(0, slot)
        units[slot].o.flags.remove(.bulletIsBig)
        units[slot].o.script.reset()
        unitUntargetMe(slot)
        units[slot].o.flags.insert(.isNotOnMap)
        unitHouseUnitCountRemove(slot)
    }

    /// `Structure_GetStructuresBuilt` (`structure.c:1378`): the bitmask of structure types `houseID` has on
    /// the map (excluding slabs/walls and off-map structures), recounting the house's windtraps as a side
    /// effect (`bit N` = structure type `N` is built).
    mutating func structureGetStructuresBuilt(houseID: UInt8) -> UInt32 {
        var result: UInt32 = 0
        houses[Int(houseID)].windtrapCount = 0
        var find = PoolFind(houseID: houseID)
        while let s = structureFind(&find) {
            if structures[s].o.flags.contains(.isNotOnMap) { continue }
            let t = structures[s].o.type
            if t == UInt8(StructureType.slab1x1.rawValue) || t == UInt8(StructureType.slab2x2.rawValue)
                || t == UInt8(StructureType.wall.rawValue)
            {
                continue
            }
            result |= UInt32(1) << UInt32(t)
            if t == UInt8(StructureType.windtrap.rawValue) { houses[Int(houseID)].windtrapCount &+= 1 }
        }
        return result
    }

    /// `House_CalculatePowerAndCredit` (`house.c:470`): recompute house `houseID`'s power usage/production
    /// and credit storage by summing over its structures. A structure with `powerUsage >= 0` consumes that
    /// much; a power plant (`powerUsage < 0`) produces `-powerUsage`, scaled by hitpoints when damaged —
    /// 1.07: a plant at ≤ half HP produces half, otherwise `-powerUsage * hp / maxHP`. The player
    /// low-power warning + the no-silo credit reset (`g_playerCreditsNoSilo`) are GUI/player-economy seams.
    mutating func houseCalculatePowerAndCredit(_ houseID: UInt8) {
        let h = Int(houseID)
        houses[h].powerUsage = 0
        houses[h].powerProduction = 0
        houses[h].creditsStorage = 0

        var find = PoolFind(houseID: houseID)
        while let s = structureFind(&find) {
            guard let st = StructureType(rawValue: Int(structures[s].o.type)) else { continue }
            let si = StructureInfo[st]
            houses[h].creditsStorage = houses[h].creditsStorage &+ si.creditsStorage

            if si.powerUsage >= 0 {
                houses[h].powerUsage = houses[h].powerUsage &+ UInt16(si.powerUsage)
                continue
            }
            let capacity = UInt16(-Int(si.powerUsage))  // a plant's full production
            let hp = structures[s].o.hitpoints
            let maxHP = si.o.hitpoints
            if hp >= maxHP {
                houses[h].powerProduction &+= capacity
            } else if hp <= maxHP / 2 {  // 1.07: ≤ half HP → half output
                houses[h].powerProduction &+= capacity / 2
            } else {
                houses[h].powerProduction &+= UInt16(UInt32(capacity) * UInt32(hp) / UInt32(max(maxHP, 1)))
            }
        }
        // SEAM: player low-power GUI warning; the `g_playerCreditsNoSilo` reset when structuresBuilt == 0.
    }

    /// `Structure_CalculateHitpointsMax` (`structure.c:623`): rescale every one of house `houseID`'s
    /// structures' max HP by its current power ratio. `power = 256` at full supply (`powerUsage == 0`),
    /// else `min(powerProduction * 256 / powerUsage, 256)`. Each structure (slabs/walls excluded) gets
    /// `hitpointsMax = info.hitpoints * power / 256`, floored at half its default HP; if that drops the cap
    /// below its current HP, it bleeds 1 HP (`Structure_Damage(s, 1, 0)`) so under-powered bases decay.
    /// The player-only `House_UpdateRadarState` is a GUI/radar seam.
    mutating func structureCalculateHitpointsMax(_ houseID: UInt8) {
        let h = Int(houseID)
        // SEAM: House_UpdateRadarState(h) for the player house.
        let power: UInt32
        if houses[h].powerUsage == 0 {
            power = 256
        } else {
            power = min(UInt32(houses[h].powerProduction) &* 256 / UInt32(houses[h].powerUsage), 256)
        }

        var find = PoolFind(houseID: houseID)
        while let s = structureFind(&find) {
            let t = structures[s].o.type
            if t == UInt8(StructureType.slab1x1.rawValue) || t == UInt8(StructureType.slab2x2.rawValue)
                || t == UInt8(StructureType.wall.rawValue)
            {
                continue
            }
            guard let st = StructureType(rawValue: Int(t)) else { continue }
            let si = StructureInfo[st]

            var hpMax = UInt16(UInt32(si.o.hitpoints) &* power / 256)
            hpMax = max(hpMax, si.o.hitpoints / 2)
            structures[s].hitpointsMax = hpMax

            if hpMax >= structures[s].o.hitpoints { continue }
            _ = structureDamage(s, damage: 1, range: 0)
        }
        houseUpdateRadarState(houseID)  // structure.c:630 (player-only inside)
    }

    /// `House_UpdateRadarState` (`house.c:402`): toggle the player's minimap radar as its outpost + power
    /// come and go, announcing "radar activated/deactivated" (feedback 28/29) on a change. Player-only; the
    /// WSA static-noise transition + the `Voice_Play(62)` static are GUI seams. RNG-free ⇒ golden-neutral
    /// (the `radarActivated` flag + the feedback aren't dumped, and no RNG is drawn).
    mutating func houseUpdateRadarState(_ houseID: UInt8) {
        guard houseID == playerHouseID else { return }
        let h = Int(houseID)
        let hasOutpost = houses[h].structuresBuilt & (UInt32(1) << UInt32(StructureType.outpost.rawValue)) != 0
        let active = hasOutpost && houses[h].powerProduction >= houses[h].powerUsage
        if houses[h].flags.contains(.radarActivated) == active { return }
        if active { houses[h].flags.insert(.radarActivated) } else { houses[h].flags.remove(.radarActivated) }
        pendingFeedback.append(active ? 28 : 29)
    }

    /// `Structure_IsUpgradable` (`structure.c:1102`): can structure `slot` still be upgraded at its current
    /// `upgradeLevel` in the active `campaignID`? Gates the upgrade chain — the upgrade-finish path sets
    /// `upgradeTimeLeft` to 100 when a further upgrade remains, else 0. Per-house/-type exclusions (Harkonnen
    /// Hi-Tech, the Ordos Heavy-Vehicle level-2 campaign gate, the Harkonnen WOR late-campaign unlock), then
    /// the generic `upgradeCampaign[level]` test; the construction yard's 2nd upgrade also needs the rocket
    /// turret's prerequisite structures. A level past the 3-entry `upgradeCampaign` table is not upgradable
    /// (Swift-guards the OOB read OpenDUNE leaves implicit for the Ordos Heavy-Vehicle level-3 case).
    /// `Structure_SetRepairingState` (`structure.c:1735`): start/stop a structure's self-repair (the
    /// `tickStructure` repair branch acts on `.repairing`). `state`: 1 start, 0 stop, −1 toggle. Starting
    /// requires the structure allocated + below full HP. Sets `.onHold` while repairing (production pauses).
    /// The `Widget`/`GUI_DisplayText` feedback is a GUI seam; `g_dune2_enhanced` is pinned false (1.07).
    /// Returns whether it acted.
    @discardableResult
    mutating func structureSetRepairingState(_ slot: Int, state: Int8) -> Bool {
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return false }
        var state = state
        var ret = false
        if !structures[slot].o.flags.contains(.allocated) { state = 0 }
        if state == -1 { state = structures[slot].o.flags.contains(.repairing) ? 0 : 1 }

        if state == 0 && structures[slot].o.flags.contains(.repairing) {
            structures[slot].o.flags.remove(.repairing)
            structures[slot].o.flags.remove(.onHold)
            ret = true
        }
        if state == 0 || structures[slot].o.flags.contains(.repairing)
            || structures[slot].o.hitpoints == StructureInfo[st].o.hitpoints
        {
            return ret
        }

        structures[slot].o.flags.insert(.onHold)
        structures[slot].o.flags.insert(.repairing)
        return true
    }

    /// Pause an in-progress build — the player clicking the "%d%% DONE" item (`gui/widget_click.c:124`, the
    /// `STR_D_DONE` case): set `.onHold` so `tickStructure`'s factory branch stops advancing (and billing)
    /// the build. A no-op visible result unless a build is actually in progress (the client only offers Pause
    /// then). Returns whether a build was in progress to pause.
    @discardableResult
    mutating func structurePauseBuild(_ slot: Int) -> Bool {
        guard slot >= 0, slot < structures.count else { return false }
        let building = structures[slot].o.linkedID != 0xFF && structures[slot].countDown != 0
        structures[slot].o.flags.insert(.onHold)
        return building
    }

    /// Resume a held structure — the player clicking the "ON HOLD" build/repair/upgrade item
    /// (`gui/widget_click.c:107`, the `STR_ON_HOLD` case): clear `.repairing`/`.onHold`/`.upgrading` so the
    /// next `tickStructure` continues. A build only actually advances once the house has credits again (the
    /// `tickStructure` factory branch re-sets `.onHold` the same tick if still underfunded), so this is a
    /// no-op for the player who's still broke — exactly as in the original. Returns whether anything was held.
    @discardableResult
    mutating func structureResumeBuild(_ slot: Int) -> Bool {
        guard slot >= 0, slot < structures.count else { return false }
        let held =
            structures[slot].o.flags.contains(.onHold)
            || structures[slot].o.flags.contains(.repairing) || structures[slot].o.flags.contains(.upgrading)
        structures[slot].o.flags.remove(.repairing)
        structures[slot].o.flags.remove(.onHold)
        structures[slot].o.flags.remove(.upgrading)
        return held
    }

    /// `Structure_CancelBuild` (`structure.c:1412`): abort the structure's in-progress build, free the
    /// queued (off-map) unit/structure, and refund the credits proportional to the unbuilt remainder. A
    /// no-op when nothing is being built (`linkedID == 0xFF`).
    mutating func structureCancelBuild(_ slot: Int) {
        if structures[slot].o.linkedID == 0xFF { return }
        let buildTime: UInt16, buildCredits: UInt16
        let linked = Int(structures[slot].o.linkedID)
        if structures[slot].o.type == UInt8(StructureType.constructionYard.rawValue) {
            guard let st2 = StructureType(rawValue: Int(structures[linked].o.type)) else { return }
            buildTime = StructureInfo[st2].o.buildTime; buildCredits = StructureInfo[st2].o.buildCredits
            structureFree(linked)
        } else {
            guard let ut = UnitType(rawValue: Int(units[linked].o.type)) else { return }
            buildTime = UnitInfo[ut].o.buildTime; buildCredits = UnitInfo[ut].o.buildCredits
            unitFree(linked)
        }
        if buildTime != 0 {
            let refund =
                (Int(buildTime) - Int(structures[slot].countDown >> 8)) * 256 / Int(buildTime) * Int(buildCredits) / 256
            let h = Int(structures[slot].o.houseID)
            houses[h].credits = UInt16(truncatingIfNeeded: Int(houses[h].credits) + refund)
        }
        structures[slot].o.flags.remove(.onHold)
        structures[slot].countDown = 0
        structures[slot].o.linkedID = 0xFF
    }

    /// `Structure_SetUpgradingState` (`structure.c:1691`): start/stop a structure's upgrade (the
    /// `tickStructure` upgrade branch acts on `.upgrading`). `state`: 1 start, 0 stop, −1 toggle. Starting
    /// requires `upgradeTimeLeft != 0`, clears `.repairing`, and sets `.onHold`. GUI feedback is a seam.
    /// Returns whether it acted.
    @discardableResult
    mutating func structureSetUpgradingState(_ slot: Int, state: Int8) -> Bool {
        var state = state
        var ret = false
        if state == -1 { state = structures[slot].o.flags.contains(.upgrading) ? 0 : 1 }

        if state == 0 && structures[slot].o.flags.contains(.upgrading) {
            structures[slot].o.flags.remove(.upgrading)
            structures[slot].o.flags.remove(.onHold)
            ret = true
        }
        if state == 0 || structures[slot].o.flags.contains(.upgrading)
            || structures[slot].upgradeTimeLeft == 0
        {
            return ret
        }

        structures[slot].o.flags.insert(.onHold)
        structures[slot].o.flags.remove(.repairing)
        structures[slot].o.flags.insert(.upgrading)
        return true
    }

    func structureIsUpgradable(_ slot: Int) -> Bool {
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return false }
        let si = StructureInfo[st]
        let houseID = structures[slot].o.houseID
        let level = Int(structures[slot].upgradeLevel)

        if houseID == UInt8(HouseID.harkonnen.rawValue), st == .highTech { return false }
        if houseID == UInt8(HouseID.ordos.rawValue), st == .heavyVehicle, level == 1,
            si.upgradeCampaign[2] > UInt16(campaignID)
        {
            return false
        }

        if level < si.upgradeCampaign.count, si.upgradeCampaign[level] != 0,
            si.upgradeCampaign[level] <= UInt16(campaignID) + 1
        {
            if st != .constructionYard { return true }
            if level != 1 { return true }
            let required = StructureInfo[.rocketTurret].o.structuresRequired
            return houses[Int(houseID)].structuresBuilt & required == required
        }

        if houseID == UInt8(HouseID.harkonnen.rawValue), st == .worTrooper, level == 0, campaignID > 3 {
            return true
        }
        return false
    }

    /// Arm the upgrade state of every **placed** factory the way `Structure_Create` (`structure.c:373`) does
    /// when the original loads a scenario (`Scenario_Load_Structure` calls `Structure_Create`): a factory that
    /// can still be upgraded gets `upgradeTimeLeft = 100` (so the GUI offers Upgrade), and an **AI**-owned
    /// factory is taken straight to its maximum upgrade level (`while IsUpgradable { upgradeLevel++ }`, then
    /// `upgradeTimeLeft = 0`). Our `ScenarioLoader.loadStructure` hand-rolls structure init and skips this, so
    /// without this pass a loaded construction yard never shows the upgrade option. Must run **after**
    /// `campaignID` + `playerHouseID` are set (both gate `structureIsUpgradable`), so the client calls it once
    /// post-load rather than inside the parity-golden `loadScenario` path (which leaves those globals unset).
    mutating func armPlacedFactoryUpgrades() {
        for slot in structures.indices where structures[slot].o.flags.contains(.used) {
            guard
                let st = StructureType(rawValue: Int(structures[slot].o.type)),
                StructureInfo[st].o.flags.contains(.factory)
            else { continue }
            let houseID = structures[slot].o.houseID
            if houseID == UInt8(HouseID.harkonnen.rawValue), st == .lightVehicle { structures[slot].upgradeLevel = 1 }
            structures[slot].upgradeTimeLeft = structureIsUpgradable(slot) ? 100 : 0
            if houseID != playerHouseID {
                while structureIsUpgradable(slot) { structures[slot].upgradeLevel &+= 1 }
                structures[slot].upgradeTimeLeft = 0
            }
        }
    }

    /// The `tickStructure` body of `GameLoop_Structure` (`structure.c:53`, the `if (tickStructure)` block):
    /// one structure's per-tick build/repair economy, run every `AdjustToGameSpeed(30,15,60)` ticks. Three
    /// mutually-exclusive branches on the structure's flags:
    ///   - **upgrading** — pay 1/40 build cost per tick, advance `upgradeTimeLeft` by 5, finish → bump
    ///     `upgradeLevel` and re-arm via `Structure_IsUpgradable`. Out of money cancels.
    ///   - **repairing** — structure self-repair: bill the 1.07 repair cost, heal HP (+5 for the player /
    ///     campaign ≥ 3, else +3), finish at full HP. Out of money cancels the repair.
    ///   - **else (factory production)** — a BUSY factory with a queued object (`countDown != 0`,
    ///     `linkedID != 0xFF`) advances its build by `buildSpeed` (HP-scaled), billing `buildCost` credits;
    ///     completing → `STRUCTURE_STATE_READY`. Out of money puts the player's build on hold. The repair
    ///     pad (`STRUCTURE_REPAIR`) additionally advances a linked unit's repair countdown.
    /// Seams here are the player completion GUI text + sound. The AI auto-place of a finished construction-yard
    /// structure and the AI-maintenance block (auto-repair + `Structure_AI_PickNextToBuild`/`BuildObject`) live
    /// in the Simulation layer (`aiStructureMaintenance`), which the caller runs right after this; degrade +
    /// palace are separate cursors also handled by the caller.
    mutating func structureTickStructure(_ slot: Int) {
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return }
        let si = StructureInfo[st]
        let hID = Int(structures[slot].o.houseID)

        if structures[slot].o.flags.contains(.upgrading) {
            // Pay 1/40 of the build cost per tick; advance `upgradeTimeLeft` in steps of 5; on completion
            // bump `upgradeLevel` (Ordos Heavy-Vehicle gets its last upgrade free → jump to 3) and re-arm
            // `upgradeTimeLeft` only if another upgrade remains. Out of money cancels the upgrade.
            let upgradeCost = si.o.buildCredits / 40
            if upgradeCost <= houses[hID].credits {
                houses[hID].credits &-= upgradeCost
                if structures[slot].upgradeTimeLeft > 5 {
                    structures[slot].upgradeTimeLeft &-= 5
                } else {
                    structures[slot].upgradeLevel &+= 1
                    structures[slot].o.flags.remove(.upgrading)
                    if structures[slot].o.houseID == UInt8(HouseID.ordos.rawValue), st == .heavyVehicle,
                        structures[slot].upgradeLevel == 2
                    {
                        structures[slot].upgradeLevel = 3
                    }
                    structures[slot].upgradeTimeLeft = structureIsUpgradable(slot) ? 100 : 0
                }
            } else {
                structures[slot].o.flags.remove(.upgrading)
            }
        } else if structures[slot].o.flags.contains(.repairing) {
            // 1.07 repair cost (the float-resolution-256 rounding OpenDUNE flags as "a bit unfair").
            let repairCost = UInt16((2 * 256 / UInt32(si.o.hitpoints) * UInt32(si.o.buildCredits) + 128) / 256)
            if repairCost <= houses[hID].credits {
                houses[hID].credits &-= repairCost
                let heal: UInt16 = (structures[slot].o.houseID == playerHouseID || campaignID >= 3) ? 5 : 3
                structures[slot].o.hitpoints &+= heal
                if structures[slot].o.hitpoints > si.o.hitpoints {
                    structures[slot].o.hitpoints = si.o.hitpoints
                    structures[slot].o.flags.remove(.repairing)
                    structures[slot].o.flags.remove(.onHold)
                }
            } else {
                structures[slot].o.flags.remove(.repairing)
            }
        } else {
            // Factory production: advance a queued build.
            if !structures[slot].o.flags.contains(.onHold), structures[slot].countDown != 0,
                structures[slot].o.linkedID != 0xFF, structures[slot].state == .busy, si.o.flags.contains(.factory)
            {
                let buildCredits: UInt16, buildTime: UInt16
                if st == .constructionYard {
                    let oi = StructureInfo[StructureType(rawValue: Int(structures[slot].objectType))!].o
                    (buildCredits, buildTime) = (oi.buildCredits, oi.buildTime)
                } else if st == .repair {
                    let ut = UnitType(rawValue: Int(units[Int(structures[slot].o.linkedID)].o.type))!
                    (buildCredits, buildTime) = (UnitInfo[ut].o.buildCredits, UnitInfo[ut].o.buildTime)
                } else {
                    let ut = UnitType(rawValue: Int(structures[slot].objectType))!
                    (buildCredits, buildTime) = (UnitInfo[ut].o.buildCredits, UnitInfo[ut].o.buildTime)
                }

                var buildSpeed: UInt32 = 256
                if structures[slot].o.hitpoints < si.o.hitpoints {
                    buildSpeed = UInt32(structures[slot].o.hitpoints) * 256 / UInt32(si.o.hitpoints)
                }
                // AIs build slower in all but the last campaign.
                if playerHouseID != structures[slot].o.houseID {
                    let cap = UInt32(campaignID) * 20 + 95
                    if buildSpeed > cap { buildSpeed = cap }
                }

                var buildCost = UInt32(buildCredits) * 256 / UInt32(buildTime)
                if buildSpeed < 256 { buildCost = buildSpeed * buildCost / 256 }
                if st == .repair, buildCost > 4 { buildCost /= 4 }
                buildCost += UInt32(structures[slot].buildCostRemainder)

                if buildCost / 256 <= UInt32(houses[hID].credits) {
                    structures[slot].buildCostRemainder = UInt16(buildCost & 0xFF)
                    houses[hID].credits &-= UInt16(buildCost / 256)
                    if buildSpeed < UInt32(structures[slot].countDown) {
                        structures[slot].countDown &-= UInt16(buildSpeed)
                    } else {
                        structures[slot].countDown = 0
                        structures[slot].buildCostRemainder = 0
                        structureSetState(slot, .ready)
                        // SEAM: player completion GUI text + Sound_Output_Feedback.
                        // (AI construction-yard auto-place runs in the Simulation's `aiStructureMaintenance`.)
                    }
                } else if structures[slot].o.houseID == playerHouseID {
                    structures[slot].o.flags.insert(.onHold)  // out of money → hold (+ GUI text SEAM)
                }
            }

            // The repair pad also drives a linked unit's repair countdown.
            if st == .repair {
                if !structures[slot].o.flags.contains(.onHold), structures[slot].countDown != 0,
                    structures[slot].o.linkedID != 0xFF
                {
                    let ut = UnitType(rawValue: Int(units[Int(structures[slot].o.linkedID)].o.type))!
                    var repairSpeed: UInt32 = 256
                    if structures[slot].o.hitpoints < si.o.hitpoints {
                        repairSpeed = UInt32(structures[slot].o.hitpoints) * 256 / UInt32(si.o.hitpoints)
                    }
                    // XXX (OpenDUNE): repairing a more-damaged pad costs more — faithfully reproduced.
                    let repairCost = UInt16(2 * UInt32(UnitInfo[ut].o.buildCredits) / 256)
                    if repairCost < houses[hID].credits {
                        houses[hID].credits &-= repairCost
                        if repairSpeed < UInt32(structures[slot].countDown) {
                            structures[slot].countDown &-= UInt16(repairSpeed)
                        } else {
                            structures[slot].countDown = 0
                            structureSetState(slot, .ready)
                            // SEAM: Sound_Output_Feedback.
                        }
                    }
                } else if houses[hID].credits != 0 {
                    structures[slot].o.flags.remove(.onHold)  // money is back → auto-resume
                }
            }
        }
    }

    /// `Unit_EnterStructure` (`unit.c:2177`): a unit arrives inside structure `s`. If the unit is gone or the
    /// structure is dead, just remove the unit. **Allied** (the harvester→refinery / unit→repair case): the
    /// structure goes READY/BUSY, a repair pad heals + times the unit, and the unit links into the
    /// structure's chain and stays (hidden, not removed). A **saboteur** detonates the structure. An **enemy**
    /// unit captures a low-HP enemy structure (houseID swap + rebuild the structures-built masks) or else
    /// damages it. Seams: the `g_unitSelected` deselect (render/UI) and `House_CalculatePowerAndCredit` (the
    /// House power/credit recompute — House subsystem); the 1.07-enhanced takeover untarget/unveil are off.
    mutating func unitEnterStructure(_ unitSlot: Int, _ structureSlot: Int) {
        guard
            let ut = UnitType(rawValue: Int(units[unitSlot].o.type)),
            let st = StructureType(rawValue: Int(structures[structureSlot].o.type))
        else { return }
        let ui = UnitInfo[ut]
        let si = StructureInfo[st]
        // SEAM: g_unitSelected → Unit_Select(NULL) / Map_SetSelection (render/UI).

        if !units[unitSlot].o.flags.contains(.allocated) || structures[structureSlot].o.hitpoints == 0 {
            unitRemove(unitSlot)
            return
        }

        units[unitSlot].o.seenByHouses |= structures[structureSlot].o.seenByHouses
        unitHide(unitSlot)

        // Allied: the structure receives the unit (harvester refines, repair heals) and links it in.
        if House.areAllied(
            structures[structureSlot].o.houseID,
            unitHouseID(units[unitSlot]),
            playerHouseID: playerHouseID
        ) {
            structureSetState(structureSlot, si.o.flags.contains(.busyStateIsIncoming) ? .ready : .busy)

            if st == .repair {
                let maxHP = UInt32(ui.o.hitpoints)
                var countDown: UInt16 = 1
                if maxHP > 0 {
                    let cd =
                        (maxHP - UInt32(units[unitSlot].o.hitpoints)) * 256 / maxHP
                        * (UInt32(ui.o.buildTime) << 6) / 256
                    countDown = cd > 1 ? UInt16(truncatingIfNeeded: cd) : 1
                }
                structures[structureSlot].countDown = countDown
                units[unitSlot].o.hitpoints = ui.o.hitpoints
                units[unitSlot].o.flags.remove(.isSmoking)
                units[unitSlot].spriteOffset = 0
            }
            units[unitSlot].o.linkedID = structures[structureSlot].o.linkedID
            structures[structureSlot].o.linkedID = UInt8(truncatingIfNeeded: units[unitSlot].o.index & 0xFF)
            return
        }

        if ut == .saboteur {
            structureDamage(structureSlot, damage: 500, range: 1)
            unitRemove(unitSlot)
            return
        }

        // Take over a low-HP enemy structure, else damage it.
        if structures[structureSlot].o.hitpoints < si.o.hitpoints / 4 {
            let captor = unitHouseID(units[unitSlot])
            let oldHouse = Int(structures[structureSlot].o.houseID)
            structures[structureSlot].o.houseID = captor
            houses[oldHouse].structuresBuilt = structureGetStructuresBuilt(houseID: UInt8(oldHouse))
            houseCalculatePowerAndCredit(UInt8(oldHouse))
            houses[Int(captor)].structuresBuilt = structureGetStructuresBuilt(houseID: captor)
            let linkedID = structures[structureSlot].o.linkedID
            if linkedID != 0xFF { units[Int(linkedID)].o.houseID = captor }
            houseCalculatePowerAndCredit(captor)
            structureUpdateMap(structureSlot)
        } else {
            let dmg = min(UInt16(units[unitSlot].o.hitpoints) &* 2, structures[structureSlot].o.hitpoints / 2)
            structureDamage(structureSlot, damage: dmg, range: 1)
        }

        objectScriptVariable4Clear(.structure(structureSlot))
        unitRemove(unitSlot)
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
        units[slot].o.seenByHouses = 0  // ENHANCEMENT (g_dune2_enhanced), which we pin true here
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
            if allied { houses[Int(houseID)].unitCountAllied &+= 1 } else { houses[Int(houseID)].unitCountEnemy &+= 1 }
        }

        if ui.movementType != .winger && !allied {
            houses[Int(houseID)].flags.insert(.isAIActive)
            houses[Int(unitHouse)].flags.insert(.isAIActive)
        }

        // Debug `aiFogOfWar`: the player sighting an enemy unit is contact — reveal the player base to that
        // unit's house so it commits. No-op with the flag off, or if already found / allied. (Only the
        // player ever calls this, so `houseID == playerHouseID` here is the player making contact.)
        if !allied && houseID == playerHouseID { aiFogReveal(toEnemyHouse: unitHouse) }

        // Player-alert block (`Unit_HouseUnitCount_Add`, unit.c:2699): when the player first sights a threat
        // (gated by the per-house suppression timers), raise the spoken warning. The `g_selectionType !=
        // MENTAT` gate is always true in-game. RNG-free ⇒ golden-neutral (the timers + the team's var4 aren't
        // dumped and draw no RNG). The host also switches to battle music on these threat feedbacks.
        if houseID == playerHouseID {
            if ut == .sandworm {
                if houses[Int(houseID)].timerSandwormAttack == 0 {
                    pendingFeedback.append(37)  // "Warning: sandworms roam Dune…"
                    houses[Int(houseID)].timerSandwormAttack = 8
                }
            } else if !allied {
                if houses[Int(houseID)].timerUnitAttack == 0 {
                    if ut == .saboteur {
                        pendingFeedback.append(12)  // "Warning: saboteur approaching"
                    } else if campaignID < 3 {
                        // Directional warning relative to the player's construction yard (or the non-directional
                        // feedback 1 if there is none): "enemy unit approaching from the <N/E/S/W>".
                        var feedbackID: UInt16 = 1
                        var find = PoolFind(
                            houseID: playerHouseID,
                            type: UInt16(StructureType.constructionYard.rawValue)
                        )
                        if let cy = structureFind(&find) {
                            let dir8 = Orientation.to8(
                                UInt8(
                                    bitPattern: Tile32.direction(
                                        from: structures[cy].o.position,
                                        to: units[slot].o.position
                                    )
                                )
                            )
                            feedbackID = UInt16((Int(dir8) + 1) & 7) / 2 + 2
                        }
                        pendingFeedback.append(feedbackID)
                    } else {
                        pendingFeedback.append(UInt16(units[slot].o.houseID) &+ 6)  // late campaign: house-specific
                    }
                    houses[Int(houseID)].timerUnitAttack = 8
                }
                if units[slot].team != 0 { teams[Int(units[slot].team) - 1].script.variables[4] = 1 }
            }
        }
        // SEAM: ambush → Unit_SetAction(HUNT) reaction — needs the EMC script VM (Tier-F #19).

        // Player-owned (and the player's Fremen allies) reveal to all houses (`0xFF`) in stock Dune II;
        // with `aiFogOfWar` on, only to the player + AI houses that have already found the player. `|= mask`
        // equals `= 0xFF` with the flag off, so the stock path is byte-identical. (unit.c)
        if unitHouse == UInt8(HouseID.fremen.rawValue) && playerHouseID == UInt8(HouseID.atreides.rawValue)
            || units[slot].o.houseID == playerHouseID
        {
            units[slot].o.seenByHouses |= playerObjectVisibilityMask()
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
            // `Unit_UpdateMap` (`unit.c:2498`): a player-allied, non-sandworm unit lifts the player's fog
            // (radius 1) on the tile it now occupies. This is the **continuous** reveal — it fires every
            // time the unit steps onto a new tile (each move step re-stamps via `unitUpdateMap(1)`), not
            // only when the unit's script happens to call `Script_Unit_RemoveFog`.
            if House.areAllied(unitHouseID(u), playerHouseID, playerHouseID: playerHouseID),
                u.o.type != UInt8(UnitType.sandworm.rawValue), !map[Int(packed)].isUnveiled
            {
                tileRemoveFogInRadius(u.o.position, radius: 1)
            }
            let occupied = map[Int(packed)].hasUnit || map[Int(packed)].hasStructure
            if !occupied {
                map[Int(packed)].index = UInt8(truncatingIfNeeded: slot + 1)
                map[Int(packed)].hasUnit = true
            }
        }

        if type == 0 {
            unitRemoveFromTile(slot, packed)
            if ut == .harvester {  // the only 2×1 unit — also clear its trailing tiles
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
