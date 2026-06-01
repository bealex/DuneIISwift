import DuneIIContracts
import DuneIIWorld

/// Unit combat effects — `Unit_Damage` (`unit.c:1530`) and friends. A faithful port that composes the
/// World pool/lifecycle ops (`Unit_RemovePlayer`, `Unit_UpdateMap`) + `UnitActions` (`Unit_SetAction`)
/// + `UnitMovement` (`Unit_Deviation_Decrease`). Lives beside `UnitMovement` (its sibling), reusing that
/// type's injected `actions`/`scriptInfo` so the script (re)loads stay in one place.
///
/// The audio (`Sound_Output_Feedback`), impact-explosion (`Map_MakeExplosion` #15), harvester-death
/// spice (`Map_FillCircleWithSpice`), and render-redraw (`Unit_UpdateMap(2)`) effects are seams — none
/// change the deterministic unit state this asserts, except as noted.
public struct UnitCombat: Sendable {
    public let movement: UnitMovement
    var actions: UnitActions { movement.actions }
    var scriptInfo: ScriptInfo { movement.scriptInfo }

    public init(movement: UnitMovement) { self.movement = movement }

    /// `Unit_Deviate` (`unit.c:1241`): the combat-facing entry point. The port lives on `UnitMovement`
    /// (also driven by `Map_DeviateArea` in `Unit_Move`); this delegates so the logic has one home.
    @discardableResult
    public func deviate(slot: Int, probability: UInt16, houseID: UInt8, in state: inout GameState) -> Bool {
        movement.deviate(slot: slot, probability: probability, houseID: houseID, in: &state)
    }

    /// `Unit_Damage` (`unit.c:1530`): apply `damage` to the unit, returning true iff it died. The port
    /// lives on `UnitMovement` (it is also driven by `Unit_Move`'s explosions — see `UnitImpact.swift`);
    /// this is the combat-facing entry point and simply delegates.
    @discardableResult
    public func damage(slot: Int, damage: UInt16, range: UInt16, in state: inout GameState) -> Bool {
        movement.damage(slot: slot, damage: damage, range: range, in: &state)
    }

    /// `Script_Unit_IsValidDestination` (op 0x2F, `script/unit.c:1694`): can the unit (carrying a linked
    /// passenger) head for the `encoded` destination? For a **tile**: 1 if off-map-invalid or carrying
    /// nothing, else 0 when the passenger could sit there unoccupied (1 otherwise). For a **structure**: 0
    /// if it's the unit's own house, 1 if carrying nothing, else whether the passenger may move into it.
    /// Temporarily relocates the linked passenger to test occupancy (the original leaves it parked off-map,
    /// matching the C — the passenger is in transport, so its position is otherwise unused).
    public func isValidDestination(slot: Int, encoded: UInt16, in state: inout GameState) -> UInt16 {
        switch Tools.indexType(encoded) {
            case .tile:
                let tile = state.indexGetTile(encoded)
                if !state.mapIsValidPosition(tile.packed) { return 1 }
                let linked = state.units[slot].o.linkedID
                if linked == 0xFF { return 1 }
                state.units[Int(linked)].o.position = tile
                if !unitIsTileOccupied(slot: Int(linked), in: state) { return 0 }
                state.units[Int(linked)].o.position = Tile32(x: 0xFFFF, y: 0xFFFF)
                return 1
            case .structure:
                guard let s = state.indexGetStructure(encoded) else { return 0 }
                if state.structures[s].o.houseID == state.unitHouseID(state.units[slot]) { return 0 }
                let linked = state.units[slot].o.linkedID
                if linked == 0xFF { return 1 }
                return movement.unit.isValidMovementIntoStructure(state.units[Int(linked)], state.structures[s], in: state) != 0 ? 1 : 0
            default:
                return 1
        }
    }

    // MARK: - Carryall transport (MoveToStructure / Pickup / TransportDeliver)

    /// `Script_Unit_MoveToStructure` (op 0x1E, `unit.c:1376`): link the carrier to (and Move toward) an
    /// idle, unlinked structure — its passenger's origin structure if it's still idle, else the nearest
    /// structure of `type` for the carrier's house. Returns the encoded structure (0 if none).
    public func moveToStructure(slot: Int, type: UInt16, in state: inout GameState) -> UInt16 {
        let unitEnc = state.indexEncode(state.units[slot].o.index, type: .unit)
        let linked = state.units[slot].o.linkedID
        if linked != 0xFF {
            let origin = state.units[Int(linked)].originEncoded
            if let s = state.indexGetStructure(origin),
               state.structures[s].state == .idle, state.structures[s].o.script.variables[4] == 0 {
                let encoded = state.indexEncode(state.structures[s].o.index, type: .structure)
                state.objectScriptVariable4Link(unitEnc, encoded)
                state.units[slot].targetMove = state.units[slot].o.script.variables[4]
                return encoded
            }
        }
        var find = PoolFind(houseID: state.unitHouseID(state.units[slot]), type: type)
        while let s = state.structureFind(&find) {
            if state.structures[s].state != .idle { continue }
            if state.structures[s].o.script.variables[4] != 0 { continue }
            let encoded = state.indexEncode(state.structures[s].o.index, type: .structure)
            state.objectScriptVariable4Link(unitEnc, encoded)
            state.units[slot].targetMove = encoded
            return encoded
        }
        return 0
    }

    /// `Script_Unit_Pickup` (op 0x22, `unit.c:225`): pick up a unit. From a READY structure (a deployed
    /// unit waiting under it) or off the ground (a unit at `targetMove`, routed to its refinery/repair pad).
    /// No-op (0) if the carrier is already carrying or there's nothing to grab.
    public func pickup(slot: Int, in state: inout GameState) -> UInt16 {
        if state.units[slot].o.linkedID != 0xFF { return 0 }

        switch Tools.indexType(state.units[slot].targetMove) {
            case .structure:
                guard let s = state.indexGetStructure(state.units[slot].targetMove) else { return 0 }
                if state.structures[s].state != .ready {
                    state.objectScriptVariable4Clear(.unit(slot))
                    state.units[slot].targetMove = 0
                    return 0
                }
                state.units[slot].o.flags.insert(.inTransport)
                state.objectScriptVariable4Clear(.unit(slot))
                state.units[slot].targetMove = 0

                let u2 = Int(state.structures[s].o.linkedID)
                state.units[slot].o.linkedID = UInt8(truncatingIfNeeded: Int(state.units[u2].o.index))
                let chain = state.units[u2].o.linkedID
                state.structures[s].o.linkedID = chain
                state.units[u2].o.linkedID = 0xFF
                if chain == 0xFF { state.structureSetState(s, .idle) }

                if state.units[u2].targetLast.x != 0 || state.units[u2].targetLast.y != 0 {
                    state.units[slot].targetMove = state.indexEncode(state.units[u2].targetLast.packed, type: .tile)
                } else if state.units[u2].o.type == UInt8(UnitType.harvester.rawValue)
                            && state.unitHouseID(state.units[u2]) != state.playerHouseID {
                    let spice = movement.map.searchSpice(state.units[slot].o.position.packed, radius: 20, in: state)
                    state.units[slot].targetMove = state.indexEncode(spice, type: .tile)
                }
                return 1

            case .unit:
                guard let u2 = state.indexGetUnit(state.units[slot].targetMove),
                      state.units[u2].o.flags.contains(.allocated) else { return 0 }
                let isHarvester = state.units[u2].o.type == UInt8(UnitType.harvester.rawValue)

                var best = -1
                var minDistance: Int16 = 0
                var find = PoolFind(houseID: state.unitHouseID(state.units[slot]))
                loop: while let s2 = state.structureFind(&find) {
                    let distance = Int16(bitPattern: Tile32.distanceRoundedUp(from: state.structures[s2].o.position,
                                                                             to: state.units[slot].o.position))
                    let wanted = isHarvester ? StructureType.refinery : .repair
                    if state.structures[s2].o.type != UInt8(wanted.rawValue)
                        || state.structures[s2].state != .idle
                        || state.structures[s2].o.script.variables[4] != 0 { continue }
                    if minDistance != 0 && distance >= minDistance { if isHarvester { break loop } else { continue } }
                    minDistance = distance
                    best = s2
                    if isHarvester { break loop }   // a harvester takes the first idle refinery
                }
                guard best != -1 else { return 0 }
                // SEAM: Unit_Select(NULL) deselect (GUI).

                state.units[slot].o.linkedID = UInt8(truncatingIfNeeded: Int(state.units[u2].o.index))
                state.units[slot].o.flags.insert(.inTransport)
                state.unitUpdateMap(0, u2)
                state.unitHide(u2)

                state.objectScriptVariable4Link(state.indexEncode(state.units[slot].o.index, type: .unit),
                                                state.indexEncode(state.structures[best].o.index, type: .structure))
                state.units[slot].targetMove = state.units[slot].o.script.variables[4]

                if !isHarvester { return 0 }
                if movement.map.searchSpice(state.units[u2].o.position.packed, radius: 2, in: state) == 0 {
                    state.units[u2].targetPreLast = Tile32(x: 0, y: 0)
                    state.units[u2].targetLast = Tile32(x: 0, y: 0)
                }
                return 0

            default:
                return 0
        }
    }

    /// `Script_Unit_TransportDeliver` (op 0x14, `unit.c:123`): drop the carrier's cargo — into a starport
    /// (busy→ready), a refinery/repair pad (`Unit_EnterStructure`), or onto the ground at the carrier's
    /// tile (`Unit_SetPosition`). No-op (0) when empty or aimed at a unit. The audio cues are seams.
    public func transportDeliver(slot: Int, in state: inout GameState) -> UInt16 {
        if state.units[slot].o.linkedID == 0xFF { return 0 }
        if Tools.indexType(state.units[slot].targetMove) == .unit { return 0 }

        if Tools.indexType(state.units[slot].targetMove) == .structure {
            guard let s = state.indexGetStructure(state.units[slot].targetMove),
                  let stype = StructureType(rawValue: Int(state.structures[s].o.type)) else { return 0 }

            if stype == .starport {
                var ret: UInt16 = 0
                if state.structures[s].state == .busy {
                    state.structures[s].o.linkedID = state.units[slot].o.linkedID
                    state.units[slot].o.linkedID = 0xFF
                    state.units[slot].o.flags.remove(.inTransport)
                    state.units[slot].amount = 0
                    state.structureSetState(s, .ready)
                    ret = 1
                }
                state.objectScriptVariable4Clear(.unit(slot))
                state.units[slot].targetMove = 0
                return ret
            }

            if (state.structures[s].state == .idle
                || (StructureInfo[stype].o.flags.contains(.busyStateIsIncoming) && state.structures[s].state == .busy))
                && state.structures[s].o.linkedID == 0xFF {
                state.unitEnterStructure(Int(state.units[slot].o.linkedID), s)
                state.objectScriptVariable4Clear(.unit(slot))
                state.units[slot].targetMove = 0
                state.units[slot].o.linkedID = 0xFF
                state.units[slot].o.flags.remove(.inTransport)
                state.units[slot].amount = 0
                return 1
            }

            state.objectScriptVariable4Clear(.unit(slot))
            state.units[slot].targetMove = 0
            return 0
        }

        // Ground drop: place the passenger at the carrier's (centred) tile.
        let drop = state.units[slot].o.position.centered
        if !state.mapIsValidPosition(drop.packed) { return 0 }
        let passenger = Int(state.units[slot].o.linkedID)
        if !unitSetPosition(slot: passenger, position: drop, in: &state) { return 0 }
        // The carryall drop cue (`Voice_PlayAtTile(24)` → DROPEQ2P), for a player-owned passenger only.
        if state.units[passenger].o.houseID == state.playerHouseID {
            state.emitSound(24, at: state.units[slot].o.position)
        }

        let facing = state.units[slot].orientation[0].current
        var u2 = state.units[passenger]
        movement.unit.setOrientation(&u2, orientation: facing, rotateInstantly: true, level: 0)
        movement.unit.setOrientation(&u2, orientation: facing, rotateInstantly: true, level: 1)
        movement.unit.setSpeed(&u2, speed: 0, gameSpeed: state.gameSpeed)
        state.units[passenger] = u2

        state.units[slot].o.linkedID = state.units[passenger].o.linkedID   // shift the next passenger in
        state.units[passenger].o.linkedID = 0xFF
        if state.units[slot].o.linkedID != 0xFF { return 1 }

        state.units[slot].o.flags.remove(.inTransport)
        state.objectScriptVariable4Clear(.unit(slot))
        state.units[slot].targetMove = 0
        return 1
    }

    // MARK: - MCV deploy + structure placement (Structure_Create / Place / IsValidBuildLocation)

    /// `Structure_IsValidBuildLocation` (`structure.c:734`): 0 if the footprint can't hold `type`, 1 if it
    /// can (all on slab), or −neededSlabs (buildable but missing N slabs → a later HP penalty). Validates
    /// bounds, terrain (`isValidForStructure`), occupancy, **and** the non-CY adjacency rule (must touch a
    /// player-house structure / slab / wall). The construction yard (MCV deploy) is exempt from adjacency.
    func structureIsValidBuildLocation(_ position: UInt16, type: StructureType, in state: GameState) -> Int16 {
        let si = StructureInfo[type]
        let layout = StructureLayoutInfo[si.layout]
        var neededSlabs: UInt16 = 0
        for i in 0 ..< Int(layout.tileCount) {
            let curPos = position &+ layout.tiles[i]
            if !state.mapIsValidPosition(curPos) { return 0 }
            let lst = movement.map.landscapeType(state.map[Int(curPos)], tileIDs: state.tileIDs)
            if si.o.flags.contains(.notOnConcrete) {
                if !LandscapeInfo[lst].isValidForStructure2 && state.validateStrictIfZero == 0 { return 0 }
            } else {
                if !LandscapeInfo[lst].isValidForStructure && state.validateStrictIfZero == 0 { return 0 }
                if lst != .concreteSlab { neededSlabs &+= 1 }
            }
            if state.unitGetByPackedTile(curPos) != nil || state.structureGetByPackedTile(curPos) != nil { return 0 }
        }
        // Adjacency (`structure.c:786`): a non-CY structure must touch a **player-house** structure, or a
        // player-owned concrete slab / wall, in the layout's surrounding ring. The construction yard (MCV
        // deploy) is exempt; the whole check is skipped when validation is relaxed (`validateStrictIfZero`).
        if state.validateStrictIfZero == 0 && type != .constructionYard {
            var adjacent = false
            for offset in layout.tilesAround {
                if offset == 0 { break }
                let curPos = Int(position) + Int(offset)
                guard curPos >= 0, curPos < state.map.count else { continue }
                if let s = state.structureGetByPackedTile(UInt16(curPos)) {
                    if state.structures[s].o.houseID != state.playerHouseID { continue }
                    adjacent = true; break
                }
                let lst = movement.map.landscapeType(state.map[curPos], tileIDs: state.tileIDs)
                if lst != .concreteSlab && lst != .wall { continue }
                if state.map[curPos].houseID != state.playerHouseID { continue }
                adjacent = true; break
            }
            if !adjacent { return 0 }
        }
        return neededSlabs == 0 ? 1 : -Int16(bitPattern: neededSlabs)
    }

    /// `Structure_Place` (`structure.c:442`), general-building case: validate the spot, stamp the footprint,
    /// remove any units under it, bump the windtrap count + recompute the house economy. The `BUILD.EMC`
    /// script is left **unloaded** — `GameLoop_Structure` loads it on the next script tick. Fog reveal +
    /// the wall/slab specials are seams. Returns false if the location is invalid (caller frees the slot).
    func structurePlace(_ slot: Int, position: UInt16, in state: inout GameState) -> Bool {
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return false }
        let si = StructureInfo[st]
        let houseID = state.structures[slot].o.houseID

        // Walls and concrete slabs live as map *tiles*, not pool objects (`Structure_Place`, `structure.c:456`
        // / `:476`): paint the wall/concrete ground tile(s) with the owner, then `Structure_Free` the
        // structure so it isn't a selectable, sprite-baked building. Without this, player-placed concrete kept
        // a slab *structure* — baking the slab's structure sprite (dark grid lines) into the ground and showing
        // a bogus "Constructing" state when selected — instead of the `builtSlab` concrete tile.
        if st == .wall {
            if structureIsValidBuildLocation(position, type: .wall, in: state) == 0 { return false }
            state.placeWall(houseID: houseID, at: position)
            state.structureFree(slot)
            return true
        }
        if st == .slab1x1 || st == .slab2x2 {
            if structureIsValidBuildLocation(position, type: st, in: state) == 0 { return false }
            state.placeSlab(st, houseID: houseID, at: position)
            state.structureFree(slot)
            return true
        }

        let valid = structureIsValidBuildLocation(position, type: st, in: state)
        if valid == 0 && houseID == state.playerHouseID && state.validateStrictIfZero == 0 { return false }

        state.structures[slot].o.seenByHouses |= UInt8(1 << houseID)
        // A player-built structure reveals to all houses (`0xFF`) in stock Dune II; with the debug
        // `aiFogOfWar` on, only to the player + AI houses that have already found the player (the mask is
        // `0xFF` with the flag off, so the stock path is unchanged). See `Architecture/AIFogOfWar.md`.
        if houseID == state.playerHouseID { state.structures[slot].o.seenByHouses |= state.playerObjectVisibilityMask() }
        state.structures[slot].o.flags.remove(.isNotOnMap)
        let corner = Tile32.unpack(position)
        state.structures[slot].o.position = Tile32(x: corner.x & 0xFF00, y: corner.y & 0xFF00)
        state.structures[slot].rotationSpriteDiff = 0
        state.structures[slot].o.hitpoints = si.o.hitpoints
        state.structures[slot].hitpointsMax = si.o.hitpoints
        if valid < 0 {
            let tilesWithoutSlab = UInt16(-valid)
            let count = UInt16(StructureLayoutInfo[si.layout].tileCount)
            state.structures[slot].o.hitpoints &-= (si.o.hitpoints / 2) &* tilesWithoutSlab / count
        }
        state.structures[slot].o.flags.insert(.degrades)   // 1.07 (non-enhanced): a placed structure always degrades
        state.structures[slot].o.script.reset()            // Script_Reset; Script_Load is deferred to GameLoop_Structure
        state.structures[slot].o.script.variables[0] = 0
        state.structures[slot].o.script.variables[4] = 0
        state.structures[slot].o.script.delay = 0

        let layout = StructureLayoutInfo[si.layout]
        for i in 0 ..< Int(layout.tileCount) {
            if let u = state.unitGetByPackedTile(position &+ layout.tiles[i]) { state.unitRemove(u) }
            // SEAM: Tile_RemoveFogInRadius (player fog reveal).
        }
        if st == .windtrap { state.houses[Int(houseID)].windtrapCount &+= 1 }
        if state.validateStrictIfZero == 0 { state.houseCalculatePowerAndCredit(houseID) }
        state.structureUpdateMap(slot)
        state.houses[Int(houseID)].structuresBuilt = state.structureGetStructuresBuilt(houseID: houseID)
        return true
    }

    /// `Structure_Create` (`structure.c:373`): allocate + initialise a structure of `type`, then place it at
    /// `position` (freeing it again if the spot is invalid). The GUI build-menu setup (`Structure_BuildObject`
    /// 0xFFFE) is a seam; an AI gets its full upgrade immediately. Returns the slot, or `nil`.
    func structureCreate(type: StructureType, houseID: UInt8, position: UInt16, in state: inout GameState) -> Int? {
        if houseID >= 6 { return nil }
        guard let slot = state.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue)) else { return nil }
        let si = StructureInfo[type]
        state.structures[slot].o.houseID = houseID
        state.structures[slot].creatorHouseID = UInt16(houseID)
        state.structures[slot].o.flags.insert(.isNotOnMap)
        state.structures[slot].o.position = Tile32(x: 0, y: 0)
        state.structures[slot].o.linkedID = 0xFF
        state.structures[slot].state = .justBuilt
        state.structures[slot].o.hitpoints = si.o.hitpoints
        state.structures[slot].hitpointsMax = si.o.hitpoints
        if houseID == UInt8(HouseID.harkonnen.rawValue) && type == .lightVehicle { state.structures[slot].upgradeLevel = 1 }
        if si.o.flags.contains(.factory) { state.structures[slot].upgradeTimeLeft = state.structureIsUpgradable(slot) ? 100 : 0 }
        state.structures[slot].objectType = 0xFFFF
        // SEAM: Structure_BuildObject(s, 0xFFFE) — the GUI build-menu / `available`-flag handler.
        state.structures[slot].countDown = 0
        if houseID != state.playerHouseID {
            while state.structureIsUpgradable(slot) { state.structures[slot].upgradeLevel &+= 1 }
            state.structures[slot].upgradeTimeLeft = 0
        }
        if position != 0xFFFF && !structurePlace(slot, position: position, in: &state) {
            state.structureFree(slot)
            return nil
        }
        return slot
    }

    /// Place the construction yard's READY structure at `position` and reset the factory, fusing the GUI's
    /// two place steps — the STR_PLACE_IT release (`widget_click.c:101`: take the linked product, clear the
    /// factory's `linkedID`) and the viewport place (`viewport.c:205`: `Structure_Place` it, spawn a
    /// refinery's harvester). Returns false (leaving the factory `.ready`) if the spot is invalid, so the
    /// caller can keep placement mode for another click. **Each** placed refinery spawns its own harvester,
    /// ferried to it (`viewport.c:210`), so a 2nd/3rd refinery each get one.
    @discardableResult
    public func structurePlaceReady(factory slot: Int, position: UInt16, in state: inout GameState) -> Bool {
        guard slot >= 0, slot < state.structures.count,
              StructureType(rawValue: Int(state.structures[slot].o.type)) == .constructionYard,
              state.structures[slot].state == .ready else { return false }
        let product = Int(state.structures[slot].o.linkedID)
        guard product != 0xFF, product < state.structures.count,
              state.structures[product].o.flags.contains(.used) else { return false }
        let placedType = StructureType(rawValue: Int(state.structures[product].o.type))
        if !structurePlace(product, position: position, in: &state) { return false }
        // The factory released the product and is free to build again (the `Structure_BuildObject(s, 0xFFFE)`
        // menu reset is a seam — we reset to idle directly).
        state.structures[slot].o.linkedID = 0xFF
        state.structures[slot].objectType = 0xFFFF
        state.structures[slot].countDown = 0
        state.structureSetState(slot, .idle)
        // A placed refinery spawns its OWN harvester, ferried to it — per refinery, NOT gated on the house
        // already having one (`viewport.c:210`: `Unit_CreateWrapper(playerHouse, HARVESTER, encode(refinery))`).
        // Pool-full ⇒ queue it as `harvestersIncoming` (the house tick retries). The placement bypasses strict
        // validation (`g_validateStrictIfZero++`), and the harvester remembers its origin refinery.
        if placedType == .refinery && state.validateStrictIfZero == 0 {
            let houseID = state.structures[product].o.houseID
            let encoded = state.indexEncode(state.structures[product].o.index, type: .structure)
            state.validateStrictIfZero &+= 1
            let harvester = unitCreateWrapper(houseID: houseID, type: .harvester, destination: encoded, in: &state)
            state.validateStrictIfZero &-= 1
            if let harvester {
                state.units[harvester].originEncoded = encoded
            } else {
                state.houses[Int(houseID)].harvestersIncoming &+= 1
            }
        }
        return true
    }

    /// `Structure_BuildObject` (`structure.c:1442`) — the **headless state-setup** path: start a factory
    /// building a concrete `objectType` (a unit, or a structure for a construction yard). Stops any repair,
    /// cancels a differing in-progress build, creates the product off-map, links it, sets the build
    /// `countDown` (`buildTime << 8`), and flips the factory to BUSY. Returns true once building.
    ///
    /// The player build GUI is **deferred to Phase 6**: the factory-window sentinels (`0xFFFD` upgrade,
    /// `0xFFFE` first-buildable, `0xFFFF` open-window) — and with them `Structure_GetBuildable` + the
    /// per-type `available` flags, the starport stock allocation, and concrete-placement hints — are seams.
    @discardableResult
    public func structureBuildObject(slot: Int, objectType: UInt16, in state: inout GameState) -> Bool {
        guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return false }
        if !StructureInfo[st].o.flags.contains(.factory) { return false }

        state.structureSetRepairingState(slot, state: 0)

        if objectType >= 0xFFFD {
            // SEAM (Phase 6): Structure_SetUpgradingState / Structure_GetBuildable + `available` flags /
            // GUI_DisplayFactoryWindow / the starport stock allocation.
            return false
        }

        if st == .starport { return true }

        if state.structures[slot].objectType != objectType { state.structureCancelBuild(slot) }
        if state.structures[slot].o.linkedID != 0xFF { return false }

        let houseID = state.structures[slot].o.houseID
        let objIndex: UInt16
        let buildTime: UInt16
        if st != .constructionYard {
            guard let ut = UnitType(rawValue: Int(objectType)),
                  let u = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(objectType), houseID: houseID,
                                     position: Tile32(x: 0xFFFF, y: 0xFFFF), orientation: 0, in: &state) else {
                state.structures[slot].o.flags.remove(.onHold)
                return false   // SEAM (player): GUI "unable to create more".
            }
            objIndex = state.units[u].o.index
            buildTime = UnitInfo[ut].o.buildTime
        } else {
            guard let st2 = StructureType(rawValue: Int(objectType)),
                  let sNew = structureCreate(type: st2, houseID: houseID, position: 0xFFFF, in: &state) else {
                state.structures[slot].o.flags.remove(.onHold)
                return false
            }
            objIndex = state.structures[sNew].o.index
            buildTime = StructureInfo[st2].o.buildTime
        }

        state.structures[slot].o.flags.remove(.onHold)
        state.structures[slot].o.linkedID = UInt8(truncatingIfNeeded: Int(objIndex))
        state.structures[slot].objectType = objectType
        state.structures[slot].countDown = UInt16(truncatingIfNeeded: Int(buildTime) << 8)
        state.structureSetState(slot, .busy)
        // SEAM (player): GUI "production of <name> has started".
        return true
    }

    /// Place **one** CHOAM order on a starport — the per-unit body of `Structure_BuildObject`'s `FACTORY_BUY`
    /// loop (`structure.c:1577`), lifted out of the factory-window GUI (which collects the per-type amounts —
    /// a Phase-6 seam). Creates the ordered unit off-map and chains it onto the house's `starportLinkedID`
    /// delivery list, arms `starportTimeLeft` if idle, and decrements the type's `starportAvailable` stock
    /// (clamped to −1 = sold out). The already-ported `tickStarport` frigate dispatch + `transportDeliver`
    /// drain that list. Returns false if `slot` isn't a starport, the type is out of stock, or the pool is
    /// full (refunding a carryall's cost, as OpenDUNE does). Credits/CHOAM pricing is charged by the GUI seam.
    @discardableResult
    /// `price` is the CHOAM amount charged on send (the GUI's `h->credits -= amount`; `widget_click.c:1308`),
    /// refunded if the unit can't be allocated. `0` (the default) keeps the EMC-only behaviour — no charge —
    /// so existing callers/goldens are unchanged; the duneii client passes the rolled `starportPrice`.
    public func structureStarportOrder(slot: Int, objectType: UInt16, price: UInt16 = 0,
                                       in state: inout GameState) -> Bool {
        guard StructureType(rawValue: Int(state.structures[slot].o.type)) == .starport,
              UnitType(rawValue: Int(objectType)) != nil else { return false }
        let typeIndex = Int(objectType)
        if typeIndex >= state.starportAvailable.count || state.starportAvailable[typeIndex] <= 0 { return false }

        let houseID = state.structures[slot].o.houseID
        let h = Int(houseID)
        let charged = min(state.houses[h].credits, price)   // the GUI greys out unaffordable orders; clamp anyway
        state.houses[h].credits &-= charged
        guard let u = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(objectType), houseID: houseID,
                                 position: Tile32(x: 0xFFFF, y: 0xFFFF), orientation: 0, in: &state) else {
            state.houses[h].credits &+= charged   // pool full — refund what we charged (GUI text seam)
            return false
        }

        if state.houses[h].starportTimeLeft == 0 {
            let hid = HouseID(rawValue: h) ?? .harkonnen
            state.houses[h].starportTimeLeft = HouseInfo[hid].starportDeliveryTime
        }
        state.units[u].o.linkedID = UInt8(truncatingIfNeeded: Int(state.houses[h].starportLinkedID))
        state.houses[h].starportLinkedID = state.units[u].o.index

        state.starportAvailable[typeIndex] &-= 1
        if state.starportAvailable[typeIndex] <= 0 { state.starportAvailable[typeIndex] = -1 }
        return true
    }

    /// `Script_Unit_MCVDeploy` (op 0x09, `script/unit.c:1846`): deploy the MCV into a construction yard at
    /// its tile (trying the tile + 3 NW offsets) and remove the MCV; returns 1 on success, else restores the
    /// MCV and returns 0 (the "can't deploy here" GUI text is a seam).
    public func mcvDeploy(slot: Int, in state: inout GameState) -> UInt16 {
        state.unitUpdateMap(0, slot)
        let base = Int(state.units[slot].o.position.packed)
        for off in [0, -1, -64, -65] {
            let pos = UInt16(truncatingIfNeeded: base + off)
            if structureCreate(type: .constructionYard, houseID: state.units[slot].o.houseID, position: pos, in: &state) != nil {
                state.unitRemove(slot)
                return 1
            }
        }
        // SEAM: GUI "unit is unable to deploy here" text.
        state.unitUpdateMap(1, slot)
        return 0
    }

    // MARK: - Spawn / summon natives (RandomSoldier / CallUnitByType)

    /// `Script_Unit_RandomSoldier` (op 0x21, `script/unit.c:48`): with probability `spawnChance/256`, spawn
    /// a `SOLDIER` near the unit (inheriting its `deviated` state) and give it `action`. The death-spray of
    /// a destroyed infantry/trooper. Draws `Random256` (the chance), `Tile_MoveByRandom` (2×), `Random256`
    /// (the soldier's facing) — that order.
    public func randomSoldier(slot: Int, action: UInt16, in state: inout GameState) -> UInt16 {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }
        if UInt16(state.random256.next()) >= UnitInfo[ut].o.spawnChance { return 0 }
        let position = Tile32.moveByRandom(state.units[slot].o.position, distance: 20, center: true, rng: &state.random256)
        let orientation = Int8(bitPattern: state.random256.next())
        guard let nu = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.soldier.rawValue),
                                  houseID: state.units[slot].o.houseID, position: position,
                                  orientation: orientation, in: &state) else { return 0 }
        state.units[nu].deviated = state.units[slot].deviated
        movement.actions.setAction(slot: nu, action: UInt8(truncatingIfNeeded: action),
                                   scriptInfo: movement.scriptInfo, in: &state)
        return 1
    }

    /// `Script_Unit_CallUnitByType` (op 0x23, `script/unit.c:1512`): summon a same-house transport of
    /// `type` (a carryall) to come collect this pickup-able, non-deviated unit — two-way `variables[4]`
    /// linking the caller and the summoned carrier, whose `targetMove` is set to the caller. Returns the
    /// encoded carrier (or the existing link / 0). Reuses the shared `Unit_CallUnitByType`.
    public func callUnitByType(slot: Int, type: UInt16, in state: inout GameState) -> UInt16 {
        let var4 = state.units[slot].o.script.variables[4]
        if var4 != 0 { return var4 }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }
        if !UnitInfo[ut].o.flags.contains(.canBePickedUp) || state.units[slot].deviated != 0 { return 0 }

        let encoded = state.indexEncode(state.units[slot].o.index, type: .unit)
        guard let u2 = unitCallUnitByType(type: UInt8(truncatingIfNeeded: type),
                                          houseID: state.unitHouseID(state.units[slot]),
                                          target: encoded, createCarryall: false, in: &state) else { return 0 }
        let encoded2 = state.indexEncode(state.units[u2].o.index, type: .unit)
        state.objectScriptVariable4Link(encoded, encoded2)
        state.units[u2].targetMove = encoded
        return encoded2
    }

    // MARK: - Spawning (Unit_Create / Unit_CreateBullet)

    /// `Unit_IsTileOccupied` (`unit.c:1789`): is the unit's current tile blocked for it? True if the
    /// landscape is impassable for its movement type, or an allied/incompatible unit or any structure sits
    /// on it. Sandworms and air units are never blocked. Read-only; composes the map + house primitives.
    public func unitIsTileOccupied(slot: Int, in state: GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return true }
        let ui = UnitInfo[ut]
        let packed = state.units[slot].o.position.packed

        let landscape = movement.map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        if LandscapeInfo[landscape].speed(ui.movementType) == 0 { return true }

        if ut == .sandworm || ui.movementType == .winger { return false }

        if let slot2 = state.unitGetByPackedTile(packed), slot2 != slot {
            if movement.house.areAllied(state.unitHouseID(state.units[slot2]), state.unitHouseID(state.units[slot]),
                                        playerHouseID: state.playerHouseID) { return true }
            if ui.movementType != .tracked { return true }
            if let ut2 = UnitType(rawValue: Int(state.units[slot2].o.type)), UnitInfo[ut2].movementType != .foot { return true }
        }

        return state.structureGetByPackedTile(packed) != nil
    }

    /// `Unit_SetPosition` (`unit.c:1107`): place `slot`'s unit (centred) at `position`. Fails — marking the
    /// unit off-map (`isNotOnMap`) — if the tile is occupied. On success it clears the unit's destination +
    /// targets, refreshes visibility if the tile is unveiled (a fresh-from-factory `seenByHouses` update),
    /// switches it to its default action (AI / harvester / saboteur → `actionAI`, else player action 3), and
    /// stamps it onto the map. Used by the structure deploy/unload natives. Returns whether it was placed.
    @discardableResult
    public func unitSetPosition(slot: Int, position: Tile32, in state: inout GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let ui = UnitInfo[ut]

        state.units[slot].o.flags.remove(.isNotOnMap)
        state.units[slot].o.position = position.centered

        if state.units[slot].originEncoded == 0 { _ = state.unitFindClosestRefinery(slot) }
        state.units[slot].o.script.variables[4] = 0

        if unitIsTileOccupied(slot: slot, in: state) {
            state.units[slot].o.flags.insert(.isNotOnMap)
            return false
        }

        state.units[slot].currentDestination = Tile32(x: 0, y: 0)
        state.units[slot].targetMove = 0
        state.units[slot].targetAttack = 0

        if state.map[Int(state.units[slot].o.position.packed)].isUnveiled {
            state.units[slot].o.seenByHouses &= ~(UInt8(1) << state.units[slot].o.houseID)
            state.unitHouseUnitCountAdd(slot, houseID: state.playerHouseID)
        }

        let action: UInt8
        if state.units[slot].o.houseID != state.playerHouseID || ut == .harvester || ut == .saboteur {
            action = UInt8(truncatingIfNeeded: ui.actionAI)
        } else {
            action = UInt8(ui.o.actionsPlayer[3].rawValue)
        }
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, in: &state)

        state.units[slot].spriteOffset = 0
        state.unitUpdateMap(1, slot)
        return true
    }

    /// `Unit_CallUnitByType` (`unit.c:2017`): find an idle (`linkedID == 0xFF`, not already moving) unit of
    /// `type`/`houseID` — the *last* one in pool order — and order it to `target` (also storing `target` in
    /// its var-4). With `createCarryall` and none free (and `type == CARRYALL`), spawn a fresh off-map
    /// scenario carryall (placement guards bypassed via `validateStrictIfZero`). Returns the unit slot, or nil.
    @discardableResult
    public func unitCallUnitByType(type: UInt8, houseID: UInt8, target: UInt16,
                                   createCarryall: Bool, in state: inout GameState) -> Int? {
        var found: Int?
        var find = PoolFind(houseID: houseID, type: UInt16(type))
        while let u = state.unitFind(&find) {
            if state.units[u].o.linkedID != 0xFF { continue }
            if state.units[u].targetMove != 0 { continue }
            found = u
        }

        if createCarryall, found == nil, type == UInt8(UnitType.carryall.rawValue) {
            state.validateStrictIfZero &+= 1
            let slot = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                  position: Tile32(x: 0, y: 0), orientation: 96, in: &state)
            state.validateStrictIfZero &-= 1
            if let slot { state.units[slot].o.flags.insert(.byScenario); found = slot }
        }

        if let f = found {
            state.units[f].targetMove = target
            state.objectScriptVariable4Set(.unit(f), target)
        }
        return found
    }

    /// `Unit_Create` (`unit.c:1380`): allocate + fully initialize a unit of `type` for `houseID` at
    /// `position` facing `orientation`, and (if on-map) place it and switch it to its default action.
    /// `index` is the desired slot or `Pool.unitIndexInvalid` for any free one. Returns the new slot, or
    /// `nil` if allocation fails or the destination tile is occupied. A `0xFFFF:0xFFFF` position creates an
    /// off-map (`isNotOnMap`) unit. The map-redraw seams are inherited from `unitUpdateMap`/`setAction`.
    @discardableResult
    public func unitCreate(index: UInt16, type: UInt8, houseID: UInt8,
                           position: Tile32, orientation: Int8, in state: inout GameState) -> Int? {
        if houseID >= 6 { return nil }                                  // HOUSE_MAX
        guard let ut = UnitType(rawValue: Int(type)) else { return nil }  // typeID >= UNIT_MAX
        let ui = UnitInfo[ut]

        guard let slot = state.unitAllocate(index: index, type: type, houseID: houseID) else { return nil }
        state.units[slot].o.houseID = houseID

        var u = state.units[slot]
        movement.unit.setOrientation(&u, orientation: orientation, rotateInstantly: true, level: 0)
        movement.unit.setOrientation(&u, orientation: orientation, rotateInstantly: true, level: 1)
        movement.unit.setSpeed(&u, speed: 0, gameSpeed: state.gameSpeed)
        state.units[slot] = u

        state.units[slot].o.position = position
        state.units[slot].o.hitpoints = ui.o.hitpoints
        state.units[slot].currentDestination = Tile32(x: 0, y: 0)
        state.units[slot].originEncoded = 0
        state.units[slot].route[0] = 0xFF

        let onMap = position.x != 0xFFFF || position.y != 0xFFFF
        if onMap {
            // Unit_FindClosestRefinery sets originEncoded internally, but Unit_Create overwrites it with
            // the function's return (`res`, 0/1) — faithful to OpenDUNE's `= Unit_FindClosestRefinery(u)`.
            let origin = state.unitFindClosestRefinery(slot)
            state.units[slot].originEncoded = origin
            state.units[slot].targetLast = position
            state.units[slot].targetPreLast = position
        }

        state.units[slot].o.linkedID = 0xFF
        state.units[slot].o.script.delay = 0
        state.units[slot].actionID = UInt8(ActionType.guard_.rawValue)
        state.units[slot].nextActionID = 0xFF   // ACTION_INVALID
        state.units[slot].fireDelay = 0
        state.units[slot].distanceToDestination = 0x7FFF
        state.units[slot].targetMove = 0
        state.units[slot].amount = 0
        state.units[slot].wobbleIndex = 0
        state.units[slot].spriteOffset = 0
        state.units[slot].blinkCounter = 0
        state.units[slot].timer = 0

        state.units[slot].o.script.reset()   // Script_Reset(&u->o.script, g_scriptUnit)
        state.units[slot].o.flags.insert(.allocated)

        if ui.movementType == .tracked {
            let chance = HouseInfo[HouseID(rawValue: Int(houseID)) ?? .harkonnen].degradingChance
            if UInt16(state.random256.next()) < chance { state.units[slot].o.flags.insert(.degrades) }
        }

        if ui.movementType == .winger {
            var u2 = state.units[slot]
            movement.unit.setSpeed(&u2, speed: 255, gameSpeed: state.gameSpeed)
            state.units[slot] = u2
        } else if onMap && unitIsTileOccupied(slot: slot, in: state) {
            state.unitFree(slot)
            return nil
        }

        if !onMap {
            state.units[slot].o.flags.insert(.isNotOnMap)
            return slot
        }

        state.unitUpdateMap(1, slot)

        let action = houseID == state.playerHouseID ? UInt8(ui.o.actionsPlayer[3].rawValue)
                                                    : UInt8(truncatingIfNeeded: ui.actionAI)
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, in: &state)
        return slot
    }

    /// `Unit_CreateWrapper` (`unit.c:1761`): spawn `type` for `houseID` at a random map edge and (for a
    /// ground unit) the carryall that ferries it to `destination`. A winger spawns directly. On a failed
    /// carryall/cargo allocation a pending harvester bumps `harvestersIncoming` so the house retries.
    /// Returns the **spawned `type`** — the ferried cargo for a ground unit (OpenDUNE returns `unit`, the
    /// cargo, *not* the carryall), or the winger itself — so a caller stamping `originEncoded` lands it on the
    /// right unit. `nil` on failure. Draws `Random256` (the spawn edge) + the `findLocationTile` LCG draws.
    @discardableResult
    public func unitCreateWrapper(houseID: UInt8, type: UnitType, destination: UInt16, in state: inout GameState) -> Int? {
        let tile = Tile32.unpack(movement.map.findLocationTile(UInt16(state.random256.next() & 3), houseID: houseID, in: &state))
        let orientation = Tile32.direction(from: tile, to: Tile32(x: 0x2000, y: 0x2000))
        let setDest = UnitScriptFunctions(unitPrimitives: movement.unit)

        if UnitInfo[type].movementType == .winger {
            state.validateStrictIfZero &+= 1
            let u = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(type.rawValue), houseID: houseID,
                               position: tile, orientation: orientation, in: &state)
            state.validateStrictIfZero &-= 1
            guard let u else { return nil }
            state.units[u].o.flags.insert(.byScenario)
            if destination != 0 { setDest.unitSetDestination(slot: u, destination, in: &state) }
            return u
        }

        state.validateStrictIfZero &+= 1
        let carryallOpt = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.carryall.rawValue),
                                     houseID: houseID, position: tile, orientation: orientation, in: &state)
        state.validateStrictIfZero &-= 1
        guard let carryall = carryallOpt else {
            if type == .harvester && state.houses[Int(houseID)].harvestersIncoming == 0 { state.houses[Int(houseID)].harvestersIncoming &+= 1 }
            return nil
        }

        if movement.house.areAllied(houseID, state.playerHouseID, playerHouseID: state.playerHouseID)
            || state.unitIsTypeOnMap(houseID: houseID, typeID: UInt8(UnitType.carryall.rawValue)) {
            state.units[carryall].o.flags.insert(.byScenario)
        }

        state.validateStrictIfZero &+= 1
        let unitOpt = unitCreate(index: Pool.unitIndexInvalid, type: UInt8(type.rawValue), houseID: houseID,
                                 position: Tile32(x: 0xFFFF, y: 0xFFFF), orientation: 0, in: &state)
        state.validateStrictIfZero &-= 1
        guard let cargo = unitOpt else {
            state.unitRemove(carryall)
            if type == .harvester && state.houses[Int(houseID)].harvestersIncoming == 0 { state.houses[Int(houseID)].harvestersIncoming &+= 1 }
            return nil
        }

        state.units[carryall].o.flags.insert(.inTransport)
        state.units[carryall].o.linkedID = UInt8(truncatingIfNeeded: Int(state.units[cargo].o.index))
        if type == .harvester { state.units[cargo].amount = 1 }
        if destination != 0 { setDest.unitSetDestination(slot: carryall, destination, in: &state) }
        return cargo   // OpenDUNE returns the ferried cargo, not the carryall (so `originEncoded` lands on it)
    }

    /// `House_EnsureHarvesterAvailable` (`house.c:298`): if the house has no harvester on the map, in a
    /// structure, or riding a carryall, dispatch a fresh one to its first refinery (via `Unit_CreateWrapper`).
    /// 1.07 non-enhanced: the structure scan skips the Heavy-Vehicle factory. The GUI text is a SEAM.
    public func houseEnsureHarvesterAvailable(houseID: UInt8, in state: inout GameState) {
        var sf = PoolFind(houseID: houseID)
        while let s = state.structureFind(&sf) {
            if state.structures[s].o.type == UInt8(StructureType.heavyVehicle.rawValue) { continue }
            let linked = state.structures[s].o.linkedID
            if linked == 0xFF { continue }
            if state.units[Int(linked)].o.type == UInt8(UnitType.harvester.rawValue) { return }
        }
        var cf = PoolFind(houseID: houseID, type: UInt16(UnitType.carryall.rawValue))
        while let u = state.unitFind(&cf) {
            let linked = state.units[u].o.linkedID
            if linked == 0xFF { continue }
            if state.units[Int(linked)].o.type == UInt8(UnitType.harvester.rawValue) { return }
        }
        if state.unitIsTypeOnMap(houseID: houseID, typeID: UInt8(UnitType.harvester.rawValue)) { return }
        var rf = PoolFind(houseID: houseID, type: UInt16(StructureType.refinery.rawValue))
        guard let refinery = state.structureFind(&rf) else { return }
        _ = unitCreateWrapper(houseID: houseID, type: .harvester,
                              destination: state.indexEncode(state.structures[refinery].o.index, type: .structure), in: &state)
        // SEAM: GUI "harvester is heading to refinery" text for the player.
    }

    /// `Unit_CreateBullet` (`unit.c:1310`): spawn a projectile of `type` from `position` toward `target`,
    /// owned by `houseID`, carrying `damage`. Missiles spawn at the firing tile and may scatter
    /// (`notAccurate`); a bullet/sonic-blast spawns one tile ahead along the line of fire and is "big" when
    /// `damage > 15`. Returns the bullet's slot, or `nil` on an invalid target / allocation failure. The
    /// `Voice_PlayAtTile` cue is an audio seam; the unseen-bullet `Tile_RemoveFogInRadius` is ported.
    @discardableResult
    public func unitCreateBullet(position: Tile32, type: UInt8, houseID: UInt8, damage: UInt16,
                                 target: UInt16, in state: inout GameState) -> Int? {
        if !state.indexIsValid(target) { return nil }
        guard let ut = UnitType(rawValue: Int(type)) else { return nil }
        let ui = UnitInfo[ut]
        let tile = state.indexGetTile(target)

        switch ut {
            case .missileHouse, .missileRocket, .missileTurret, .missileDeviator, .missileTrooper:
                let orientation = Tile32.direction(from: position, to: tile)
                guard let bullet = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                              position: position, orientation: orientation, in: &state) else { return nil }
                // SEAM: Voice_PlayAtTile(bulletSound) audio.
                state.units[bullet].targetAttack = target
                state.units[bullet].o.hitpoints = damage
                state.units[bullet].currentDestination = tile

                if ui.flags.contains(.notAccurate) {
                    let scatter: UInt16 = (state.random256.next() & 0xF) != 0
                        ? Tile32.distance(from: position, to: tile) / 256 + 8
                        : UInt16(state.random256.next()) + 8
                    state.units[bullet].currentDestination = Tile32.moveByRandom(tile, distance: scatter, center: false, rng: &state.random256)
                }

                state.units[bullet].fireDelay = ui.fireDistance & 0xFF
                if let u = state.indexGetUnit(target), let ut2 = UnitType(rawValue: Int(state.units[u].o.type)),
                   UnitInfo[ut2].movementType == .winger {
                    state.units[bullet].fireDelay <<= 1
                }

                if ut == .missileHouse || (state.units[bullet].o.seenByHouses & (1 << state.playerHouseID)) != 0 { return bullet }
                state.tileRemoveFogInRadius(state.units[bullet].o.position, radius: 2)
                return bullet

            case .bullet, .sonicBlast:
                let orientation = Tile32.direction(from: position, to: tile)
                let t = Tile32.moveByDirection(Tile32.moveByDirection(position, orientation: 0, distance: 32),
                                               orientation: Int16(orientation), distance: 128)
                guard let bullet = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                              position: t, orientation: orientation, in: &state) else { return nil }
                if ut == .sonicBlast { state.units[bullet].fireDelay = ui.fireDistance & 0xFF }
                state.units[bullet].currentDestination = tile
                state.units[bullet].o.hitpoints = damage
                if damage > 15 { state.units[bullet].o.flags.insert(.bulletIsBig) }

                if (state.units[bullet].o.seenByHouses & (1 << state.playerHouseID)) != 0 { return bullet }
                state.tileRemoveFogInRadius(state.units[bullet].o.position, radius: 2)
                return bullet

            default: return nil
        }
    }

    // MARK: - Script_Unit_Fire (native 0x08)

    /// `Script_Unit_Fire` (`script/unit.c:577`, native `0x08`): fire the unit's weapon at `targetAttack`.
    /// Faithful transcription: the early-outs (no/invalid target, self-target, still turning, retarget,
    /// fireDelay, out of range, off-aim), then `Unit_CreateBullet` (or the sandworm devour), then the
    /// post-fire `fireDelay` (with the `firesTwice` 2nd-shot short delay + the `Random256 & 1` jitter).
    /// Returns 1 if it fired, 0 otherwise. `Map_MakeExplosion` (sandworm) + the audio cues are seams.
    @discardableResult
    public func fire(slot: Int, in state: inout GameState) -> UInt16 {
        let target = state.units[slot].targetAttack
        if target == 0 || !state.indexIsValid(target) { return 0 }

        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }
        let ui = UnitInfo[ut]
        let fns = UnitScriptFunctions(unitPrimitives: movement.unit)
        let aimLevel = ui.o.flags.contains(.hasTurret) ? 1 : 0

        if ut != .sandworm && target == state.indexEncode(state.units[slot].o.position.packed, type: .tile) {
            state.units[slot].targetAttack = 0
        }
        if state.units[slot].targetAttack != target {
            fns.unitSetTarget(slot: slot, target, in: &state)
            return 0
        }

        if ut != .sandworm && state.units[slot].orientation[aimLevel].speed != 0 { return 0 }

        if Tools.indexType(target) == .tile {
            let packed = Tools.indexDecode(target)
            if state.unitGetByPackedTile(packed) != nil || state.structureGetByPackedTile(packed) != nil {
                fns.unitSetTarget(slot: slot, target, in: &state)
            }
        }

        if state.units[slot].fireDelay != 0 { return 0 }

        let distance = GeneralScriptFunctions().getDistanceToObject(from: state.units[slot].o.position, encoded: target, in: state)
        if Int16(truncatingIfNeeded: Int(ui.fireDistance) << 8) < Int16(bitPattern: distance) { return 0 }

        let targetIsWinger: Bool = state.indexGetUnit(target).flatMap { UnitType(rawValue: Int(state.units[$0].o.type)) }
            .map { UnitInfo[$0].movementType == .winger } ?? false
        if ut != .sandworm && (Tools.indexType(target) != .unit || !targetIsWinger) {
            let orientation = Tile32.direction(from: state.units[slot].o.position, to: state.indexGetTile(target))
            var diff = abs(Int(state.units[slot].orientation[aimLevel].current) - Int(orientation))
            if ui.movementType == .winger { diff /= 8 }
            if diff >= 8 { return 0 }
        }

        var damage = ui.damage
        var typeID = ui.bulletType
        let fireTwice = ui.flags.contains(.firesTwice) && state.units[slot].o.hitpoints > ui.o.hitpoints / 2
        if (ut == .troopers || ut == .trooper) && Int16(bitPattern: distance) > 512 {
            typeID = UInt8(UnitType.missileTrooper.rawValue)
        }

        switch UnitType(rawValue: Int(typeID)) {
            case .sandworm:
                state.unitUpdateMap(0, slot)
                if let target2 = state.indexGetUnit(target) {
                    state.units[target2].o.script.variables[1] = 0xFFFF
                    state.unitRemove(target2)   // Unit_RemovePlayer + HouseUnitCount_Remove are folded into unitRemove
                }
                // The "gulp" swallow animation at the worm (`Map_MakeExplosion(ui->explosionType, pos, 0, 0)`,
                // `script/unit.c`): a visual-only blast (hitpoints 0 ⇒ no damage/RNG — the prey was already
                // removed above). `ui` is the sandworm's info, so `explosionType` is EXPLOSION_SANDWORM_SWALLOW.
                movement.mapMakeExplosion(type: ui.explosionType, position: state.units[slot].o.position,
                                          hitpoints: 0, origin: 0, in: &state)
                state.emitSound(63, at: state.units[slot].o.position)   // Voice_PlayAtTile(63, …) — WORMET3P
                state.unitUpdateMap(1, slot)
                state.units[slot].amount &-= 1
                state.units[slot].o.script.delay = 12
                if Int8(bitPattern: UInt8(truncatingIfNeeded: state.units[slot].amount)) < 1 {
                    actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
                }

            case .missileTrooper, .missileRocket, .missileTurret, .missileDeviator, .bullet, .sonicBlast:
                if UnitType(rawValue: Int(typeID)) == .missileTrooper { damage -= damage / 4 }
                guard let bullet = unitCreateBullet(position: state.units[slot].o.position, type: typeID,
                                                    houseID: state.unitHouseID(state.units[slot]),
                                                    damage: damage, target: target, in: &state) else { return 0 }
                state.units[bullet].originEncoded = state.indexEncode(state.units[slot].o.index, type: .unit)
                // `Voice_PlayAtTile(ui->bulletSound, u->o.position)` (`script/unit.c:99`): the weapon sound.
                // The sim only emits the id; the host maps it to a VOC and plays it.
                state.emitSound(Int(ui.bulletSound), at: state.units[slot].o.position)
                movement.deviationDecrease(slot: slot, amount: 20, in: &state)

            default: break
        }

        state.units[slot].fireDelay = Tools.adjustToGameSpeed(normal: ui.fireDelay &* 2, minimum: 1, maximum: 0xFFFF,
                                                              inverseSpeed: true, gameSpeed: state.gameSpeed)
        if fireTwice {
            if state.units[slot].o.flags.contains(.fireTwiceFlip) { state.units[slot].o.flags.remove(.fireTwiceFlip) }
            else { state.units[slot].o.flags.insert(.fireTwiceFlip) }
            if state.units[slot].o.flags.contains(.fireTwiceFlip) {
                state.units[slot].fireDelay = Tools.adjustToGameSpeed(normal: 5, minimum: 1, maximum: 10,
                                                                      inverseSpeed: true, gameSpeed: state.gameSpeed)
            }
        } else {
            state.units[slot].o.flags.remove(.fireTwiceFlip)
        }

        state.units[slot].fireDelay &+= UInt16(state.random256.next() & 1)
        state.unitUpdateMap(2, slot)
        return 1
    }
}
