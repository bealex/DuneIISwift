import DuneIIContracts
import DuneIIWorld

/// The ground-unit movement cluster — the chain that turns a `targetMove` into a per-tick change of a
/// unit's `position`. Faithful ports of OpenDUNE `Unit_MovementTick` (`unit.c:98`), `Unit_Move`
/// (`unit.c:1286`), `Unit_StartMovement` (`unit.c:1059`), `Unit_Deviation_Decrease` (`unit.c:1174`), and
/// the script native `Script_Unit_CalculateRoute` (`script/unit.c:1308`). Composes the already-ported
/// primitives (`UnitPrimitives` set-speed/-orientation/tile-enter-score, `MapPrimitives`, the
/// `Pathfinder`) plus the World pool/map ops on `GameState`. Design: `Documentation/Algorithms/UnitMovement.md`.
///
/// Like the script runner, this is a value type holding the injected seams; both `Simulation`
/// (`GameLoop_Unit`) and `UnitScriptRunner` (the op-`0x0C` dispatch) build one and call into it.
public struct UnitMovement: Sendable {
    public let unit: any UnitPrimitives
    public let map: any MapPrimitives
    public let house: any HousePrimitives
    public let actions: UnitActions
    public let pathfinder: Pathfinder
    public let scriptInfo: ScriptInfo

    /// The death-hand (house missile) 17-point blast offsets (`unit.c:1394`): the impact tile plus a
    /// fixed inner/outer cross pattern of 16 sub-tile offsets.
    static let deathHandOffsetX: [Int16] = [
        0, 0, 200, 256, 200, 0, -200, -256, -200, 0, 400, 512, 400, 0, -400, -512, -400,
    ]
    static let deathHandOffsetY: [Int16] = [
        0, -256, -200, 0, 200, 256, 200, 0, -200, -512, -400, 0, 400, 512, 400, 0, -400,
    ]

    public init(
        scriptInfo: ScriptInfo,
        interpreter: any ScriptInterpreter = DefaultScriptInterpreter(),
        unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
        mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
        housePrimitives: any HousePrimitives = DefaultHousePrimitives()
    ) {
        self.scriptInfo = scriptInfo
        self.unit = unitPrimitives
        self.map = mapPrimitives
        self.house = housePrimitives
        self.actions = UnitActions(interpreter: interpreter)
        self.pathfinder = Pathfinder(primitives: unitPrimitives, map: mapPrimitives, house: housePrimitives)
    }

    // MARK: - Unit_MovementTick

    /// `Unit_MovementTick` (`unit.c:98`): accumulate the per-tick speed into `speedRemainder`; on a byte
    /// carry, step the unit with `Unit_Move`. Air units (`winger`) ignore gameSpeed.
    public func movementTick(slot: Int, in state: inout GameState) {
        if state.units[slot].speed == 0 { return }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return }

        let ui = UnitInfo[ut]

        var speed = UInt16(state.units[slot].speedRemainder)
        if ui.movementType != .winger {
            speed &+= Tools.adjustToGameSpeed(
                normal: UInt16(state.units[slot].speedPerTick),
                minimum: 1,
                maximum: 255,
                inverseSpeed: false,
                gameSpeed: state.gameSpeed
            )
        } else {
            speed &+= UInt16(state.units[slot].speedPerTick)
        }

        if (speed & 0xFF00) != 0 {
            let dist = Tile32.distance(from: state.units[slot].o.position, to: state.units[slot].currentDestination)
            let d = min(Int(state.units[slot].speed) * 16, Int(dist) + 16)
            move(slot: slot, distance: UInt16(truncatingIfNeeded: d), in: &state)
        }

        state.units[slot].speedRemainder = UInt8(speed & 0xFF)
    }

    // MARK: - Unit_Move

    /// `Unit_Move` (`unit.c:1286`): step the unit by `distance` sub-tile units along its current
    /// orientation, reconciling the map and handling arrival at the current waypoint. Returns true when
    /// the step completes a waypoint (or the unit was removed). The sonic-blast area damage, the
    /// death-hand 17-point blast, the saboteur arrival detonation, and the sand-burst impact are wired;
    /// the deviator-gas area (`Map_DeviateArea`) and spice-bloom detonation (`Map_Bloom_Explode*`) remain
    /// SEAMs (slice 4). None fire for a ground unit crossing open terrain. See `UnitMovement.md`.
    @discardableResult
    public func move(slot: Int, distance distance0: UInt16, in state: inout GameState) -> Bool {
        var distance = distance0
        guard state.units[slot].o.flags.contains(.used) else { return false }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }

        let ui = UnitInfo[ut]

        var newPosition = Tile32.moveByDirection(
            state.units[slot].o.position,
            orientation: Int16(state.units[slot].orientation[0].current),
            distance: distance
        )

        if newPosition.x == state.units[slot].o.position.x && newPosition.y == state.units[slot].o.position.y {
            return false
        }

        if !newPosition.isValid {
            if !ui.flags.contains(.mustStayInMap) {
                state.unitRemove(slot)
                return true
            }
            if state.units[slot].o.flags.contains(.byScenario)
                && state.units[slot].o.linkedID == 0xFF
                && state.units[slot].o.script.variables[4] == 0
            {
                state.unitRemove(slot)
                return true
            }
            newPosition = state.units[slot].o.position
            var u = state.units[slot]
            let turn = Int(u.orientation[0].current) + Int(state.random256.next() & 0xF)
            unit.setOrientation(&u, orientation: Int8(truncatingIfNeeded: turn), rotateInstantly: false, level: 0)
            state.units[slot] = u
        }

        state.units[slot].wobbleIndex = 0
        if ui.flags.contains(.canWobble) && state.units[slot].o.flags.contains(.isWobbling) {
            state.units[slot].wobbleIndex = state.random256.next() & 7
        }

        let d = Tile32.distance(from: newPosition, to: state.units[slot].currentDestination)
        let packed = newPosition.packed

        if ui.flags.contains(.isTracked) && d < 48 {
            if let u2 = state.unitGetByPackedTile(packed),
                let ut2 = UnitType(rawValue: Int(state.units[u2].o.type)),
                UnitInfo[ut2].movementType == .foot,
                state.units[u2].o.flags.contains(.allocated)
            {
                // Driving over a foot unit — it dies. (SEAM: Unit_Select(NULL) if it was selected.)
                state.unitUntargetMe(u2)
                state.units[u2].o.script.variables[1] = 1
                actions.setAction(slot: u2, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
            } else {
                let type = map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
                if (type == .normalSand || type == .entirelyDune) && state.map[Int(packed)].overlayTileID == 0 {
                    // Leave a sand track at the unit's *current* tile (it moves to `newPosition` later),
                    // facing-selected: `Animation_Start(g_table_animation_unitMove[orient8], …, iconGroup 5)`.
                    // RNG-free, so the golden draw stream is unchanged; the overlay only paints once
                    // animations are ticked (the visual apps), like the structure/corpse animations.
                    let orient8 = Orientation.to8(UInt8(bitPattern: state.units[slot].orientation[0].current))
                    state.animationStart(
                        tableIndex: Int(orient8),
                        tile: state.units[slot].o.position,
                        tileLayout: 0,
                        houseID: state.units[slot].o.houseID,
                        iconGroup: 5,
                        kind: .unitMove
                    )
                }
            }
        }

        state.unitUpdateMap(0, slot)

        if ui.movementType == .winger {
            if state.units[slot].o.flags.contains(.animationFlip) {
                state.units[slot].o.flags.remove(.animationFlip)
            } else {
                state.units[slot].o.flags.insert(.animationFlip)
            }
        }

        let currentDestination = state.units[slot].currentDestination
        distance = Tile32.distance(from: newPosition, to: currentDestination)

        var isSpiceBloom = false
        var ret = false

        if ut == .sonicBlast {
            // Sonic-blast area damage: the unit/structure on the wave's tile takes `hp/4 + 1`. A
            // sonic-protected unit (most tracked vehicles) is immune; a wall costs one RNG draw.
            let blastDamage = (state.units[slot].o.hitpoints / 4) &+ 1
            if let u2 = state.unitGetByPackedTile(packed) {
                if let ut2 = UnitType(rawValue: Int(state.units[u2].o.type)),
                    !UnitInfo[ut2].flags.contains(.sonicProtection)
                {
                    damage(slot: u2, damage: blastDamage, range: 0, in: &state)
                }
            } else if let s2 = state.structureGetByPackedTile(packed) {
                _ = state.structureDamage(s2, damage: blastDamage, range: 0)
            } else if map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs) == .wall
                && StructureInfo[.wall].o.hitpoints > blastDamage
            {
                _ = state.random256.next()
            }
            if state.units[slot].o.hitpoints < (ui.damage / 2) {
                state.units[slot].o.flags.insert(.bulletIsBig)
            }
            state.units[slot].o.hitpoints &-= 1
            if state.units[slot].o.hitpoints == 0 || state.units[slot].fireDelay == 0 {
                state.unitRemove(slot)
            }
        } else {
            if ut == .bullet {
                // Mid-flight impact: a bullet that flies into a wall / building / mountain detonates there.
                // (A bullet fired *from* a structure passes over its owner's own walls/buildings.)
                var ltype = map.landscapeType(state.map[Int(newPosition.packed)], tileIDs: state.tileIDs)
                if (ltype == .wall || ltype == .structure)
                    && Tools.indexType(state.units[slot].originEncoded) == .structure
                    && state.map[Int(newPosition.packed)].houseID == state.units[slot].o.houseID
                {
                    ltype = .normalSand
                }
                if ltype == .wall || ltype == .structure || ltype == .entirelyMountain {
                    state.units[slot].o.position = newPosition
                    mapMakeExplosion(
                        type: (ui.explosionType &+ UInt16(state.units[slot].o.hitpoints) / 10) & 3,
                        position: state.units[slot].o.position,
                        hitpoints: state.units[slot].o.hitpoints,
                        origin: state.units[slot].originEncoded,
                        in: &state
                    )
                    state.unitRemove(slot)
                    return true
                }
            }

            ret = (state.units[slot].distanceToDestination < distance) || (distance < 16)

            if ret {
                if ui.flags.contains(.isBullet) {
                    // Arrival detonation. A bullet/sonic always has fireDelay 0 here, so it explodes; a
                    // still-armed missile (fireDelay != 0, not a turret missile) keeps flying (falls through).
                    if state.units[slot].fireDelay == 0 || ut == .missileTurret {
                        if ut == .missileHouse {
                            // Death-hand 17-point blast: explode `ui.explosionType` (200 hp) at the impact
                            // tile and 16 fixed offsets around it (skipping off-map points).
                            for i in 0 ..< 17 {
                                let p = Tile32(
                                    x: newPosition.x &+ UInt16(bitPattern: Self.deathHandOffsetX[i]),
                                    y: newPosition.y &+ UInt16(bitPattern: Self.deathHandOffsetY[i])
                                )
                                if p.isValid {
                                    mapMakeExplosion(
                                        type: ui.explosionType,
                                        position: p,
                                        hitpoints: 200,
                                        origin: 0,
                                        in: &state
                                    )
                                }
                            }
                        } else if ui.explosionType != 0xFFFF {
                            if ui.flags.contains(.impactOnSand)
                                && state.map[Int(state.units[slot].o.position.packed)].index == 0
                                && map.landscapeType(
                                    state.map[Int(state.units[slot].o.position.packed)],
                                    tileIDs: state.tileIDs
                                ) == .normalSand
                            {
                                mapMakeExplosion(
                                    type: UInt16(ExplosionType.sandBurst.rawValue),
                                    position: newPosition,
                                    hitpoints: state.units[slot].o.hitpoints,
                                    origin: state.units[slot].originEncoded,
                                    in: &state
                                )
                            } else if ut == .missileDeviator {
                                mapDeviateArea(
                                    type: ui.explosionType,
                                    position: newPosition,
                                    radius: 32,
                                    houseID: state.units[slot].o.houseID,
                                    in: &state
                                )
                            } else {
                                mapMakeExplosion(
                                    type: (ui.explosionType &+ UInt16(state.units[slot].o.hitpoints) / 20) & 3,
                                    position: newPosition,
                                    hitpoints: state.units[slot].o.hitpoints,
                                    origin: state.units[slot].originEncoded,
                                    in: &state
                                )
                            }
                        }
                        state.unitRemove(slot)
                        return true
                    }
                } else if ui.flags.contains(.isGroundUnit) {
                    if currentDestination.x != 0 || currentDestination.y != 0 { newPosition = currentDestination }
                    state.units[slot].targetPreLast = state.units[slot].targetLast
                    state.units[slot].targetLast = state.units[slot].o.position
                    state.units[slot].currentDestination = Tile32(x: 0, y: 0)

                    if state.units[slot].o.flags.contains(.degrades) && (state.random256.next() & 3) == 0 {
                        damage(slot: slot, damage: 1, range: 0, in: &state)  // Unit_Damage(unit, 1, 0)
                    }

                    if ut == .saboteur {
                        // Saboteur detonates on reaching a wall, or within 32 sub-units of its move target
                        // (1.07 non-enhanced: measured from the pre-step `o.position`). 500-hp blast.
                        var detonate =
                            map.landscapeType(state.map[Int(newPosition.packed)], tileIDs: state.tileIDs) == .wall
                        if !detonate {
                            detonate =
                                state.units[slot].targetMove != 0
                                && Tile32.distance(
                                    from: state.units[slot].o.position,
                                    to: state.indexGetTile(state.units[slot].targetMove)
                                ) < 32
                        }
                        if detonate {
                            mapMakeExplosion(
                                type: UInt16(ExplosionType.saboteurDeath.rawValue),
                                position: newPosition,
                                hitpoints: 500,
                                origin: 0,
                                in: &state
                            )
                            state.unitRemove(slot)
                            return true
                        }
                    }

                    var u = state.units[slot]
                    unit.setSpeed(&u, speed: 0, gameSpeed: state.gameSpeed)
                    state.units[slot] = u

                    if state.units[slot].targetMove == state.indexEncode(packed, type: .tile) {
                        state.units[slot].targetMove = 0
                    }

                    if let s = state.structureGetByPackedTile(packed) {
                        state.units[slot].targetPreLast = Tile32(x: 0, y: 0)
                        state.units[slot].targetLast = Tile32(x: 0, y: 0)
                        state.unitEnterStructure(slot, s)  // Unit_EnterStructure(unit, s)
                        return true
                    }

                    if ut != .sandworm {
                        let g = state.map[Int(packed)].groundTileID
                        if g == state.tileIDs.bloom || g == state.tileIDs.bloom &+ 1 { isSpiceBloom = true }
                    }
                }
            }
        }

        guard state.units[slot].o.flags.contains(.used) else { return ret }  // self-removed above

        state.units[slot].distanceToDestination = distance
        state.units[slot].o.position = newPosition
        state.unitUpdateMap(1, slot)

        // A ground unit that stopped on a spice bloom detonates it. (`isSpecialBloom` is unreachable in
        // 1.07, so `Map_Bloom_ExplodeSpecial` is intentionally not wired.)
        if isSpiceBloom {
            mapBloomExplodeSpice(packed: packed, houseID: state.unitHouseID(state.units[slot]), in: &state)
        }

        return ret
    }

    // MARK: - Unit_StartMovement

    /// `Unit_StartMovement` (`unit.c:1059`): commit to the next route tile. Snap the base orientation to
    /// the nearest 8-dir, step one whole tile (`Tile_MoveByOrientation`), bail if the tile is blocked
    /// (`Unit_GetTileEnterScore`), set the landscape-derived speed, claim the destination tile, and record
    /// it as `currentDestination`. Does not move `o.position`. `engine` is threaded for the deviation-
    /// expiry `Unit_SetAction` (only reachable for a deviated unit).
    @discardableResult
    public func startMovement(slot: Int, engine: inout ScriptEngine, in state: inout GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }

        let ui = UnitInfo[ut]

        let orientation = Int8(truncatingIfNeeded: (Int(state.units[slot].orientation[0].current) + 16) & 0xE0)

        var u = state.units[slot]
        unit.setOrientation(&u, orientation: orientation, rotateInstantly: true, level: 0)
        unit.setOrientation(&u, orientation: orientation, rotateInstantly: false, level: 1)
        state.units[slot] = u

        let position = Tile32.moveByOrientation(
            state.units[slot].o.position,
            orientation: UInt8(bitPattern: orientation)
        )
        let packed = position.packed

        state.units[slot].distanceToDestination = 0x7FFF

        let score = unit.tileEnterScore(
            state.units[slot],
            packed: packed,
            orient8: UInt16(UInt8(bitPattern: orientation)) / 32,
            in: state,
            map: map,
            house: house
        )
        if score > 255 || score == -1 { return false }

        var type = map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        if type == .structure { type = .concreteSlab }

        var speed = UInt16(LandscapeInfo[type].speed(ui.movementType))
        if ut == .saboteur && type == .wall { speed = 255 }
        state.units[slot].o.flags.remove(.isSmoking)

        // ENHANCEMENT pinned false: original Dune2 only ever sets isWobbling true.
        if LandscapeInfo[type].letUnitWobble { state.units[slot].o.flags.insert(.isWobbling) }

        if Int(ui.o.hitpoints) / 2 > Int(state.units[slot].o.hitpoints) && ui.movementType != .winger {
            speed -= speed / 4
        }

        var u2 = state.units[slot]
        unit.setSpeed(&u2, speed: speed, gameSpeed: state.gameSpeed)
        state.units[slot] = u2

        if ui.movementType != .slither {
            let positionOld = state.units[slot].o.position
            state.units[slot].o.position = position
            state.unitUpdateMap(1, slot)
            state.units[slot].o.position = positionOld
        }

        state.units[slot].currentDestination = position

        deviationDecrease(slot: slot, amount: 10, engine: &engine, in: &state)
        return true
    }

    // MARK: - Unit_Deviation_Decrease

    /// `Unit_Deviation_Decrease` (`unit.c:1174`): wear down a deviated unit's deviation counter; on expiry
    /// flip the unit back to its own house's default action and clear its targets. Returns true on expiry.
    /// A non-deviated unit returns false immediately (the common path).
    @discardableResult
    public func deviationDecrease(
        slot: Int,
        amount amount0: UInt16,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) -> Bool {
        if state.units[slot].deviated == 0 { return false }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }

        let ui = UnitInfo[ut]
        if !ui.flags.contains(.isNormalUnit) { return false }

        var amount = amount0
        if amount == 0 {
            amount = UInt16(HouseInfo[HouseID(rawValue: Int(state.units[slot].o.houseID)) ?? .harkonnen].toughness)
        }

        if UInt16(state.units[slot].deviated) > amount {
            state.units[slot].deviated &-= UInt8(truncatingIfNeeded: amount)
            return false
        }

        state.units[slot].deviated = 0
        // SEAM: Unit_UpdateMap(2, …) render redraw around the bulletIsBig flip.

        let action: UInt8
        if state.units[slot].o.houseID == state.playerHouseID {
            action = UInt8(ui.o.actionsPlayer[3].rawValue)
        } else {
            action = UInt8(truncatingIfNeeded: ui.actionAI)
        }
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, engine: &engine, in: &state)

        state.unitUntargetMe(slot)
        state.units[slot].targetAttack = 0
        state.units[slot].targetMove = 0
        return true
    }

    /// Standalone `Unit_Deviation_Decrease` for callers outside a script run (e.g. `Unit_Damage`, the
    /// loop's `tickDeviation`): the unit's own `o.script` is the engine. Copied out/in around the
    /// engine-threaded core to avoid overlapping `inout` access to `state`.
    @discardableResult
    public func deviationDecrease(slot: Int, amount: UInt16, in state: inout GameState) -> Bool {
        var engine = state.units[slot].o.script
        let r = deviationDecrease(slot: slot, amount: amount, engine: &engine, in: &state)
        state.units[slot].o.script = engine
        return r
    }

    // MARK: - Script_Unit_CalculateRoute (native 0x0C)

    /// `Script_Unit_CalculateRoute` (`script/unit.c:1308`): advance one route step toward the encoded
    /// destination. Returns 0 once arrived, 1 otherwise. Computes the route via the `Pathfinder` on first
    /// call, turns the unit to face the next step (one step), then commits it via `Unit_StartMovement`.
    @discardableResult
    public func calculateRoute(slot: Int, encoded: UInt16, engine: inout ScriptEngine, in state: inout GameState)
        -> UInt16
    {
        if state.units[slot].currentDestination.x != 0 || state.units[slot].currentDestination.y != 0
            || !state.indexIsValid(encoded)
        {
            return 1
        }

        let packedSrc = state.units[slot].o.position.packed
        let packedDst = state.indexGetTile(encoded).packed

        if packedDst == packedSrc {
            state.units[slot].route[0] = 0xFF
            state.units[slot].targetMove = 0
            return 0
        }

        if state.units[slot].route[0] == 0xFF {
            let res = pathfinder.pathfind(
                src: packedSrc,
                dst: packedDst,
                unit: state.units[slot],
                bufferSize: 40,
                in: state
            )
            let n = min(res.routeSize, 14)
            for i in 0 ..< n { state.units[slot].route[i] = res.buffer[i] }

            if state.units[slot].route[0] == 0xFF {
                state.units[slot].targetMove = 0
                if UnitType(rawValue: Int(state.units[slot].o.type)) == .sandworm { engine.delay = 720 }
            }
        } else {
            let distance = Tile32.distancePacked(packedDst, packedSrc)
            if distance < 14 { state.units[slot].route[Int(distance)] = 0xFF }
        }

        if state.units[slot].route[0] == 0xFF { return 1 }

        let want = Int8(truncatingIfNeeded: Int(state.units[slot].route[0]) * 32)
        if state.units[slot].orientation[0].current != want {
            var u = state.units[slot]
            unit.setOrientation(&u, orientation: want, rotateInstantly: false, level: 0)
            state.units[slot] = u
            return 1
        }

        if !startMovement(slot: slot, engine: &engine, in: &state) {
            state.units[slot].route[0] = 0xFF
            return 0
        }

        for i in 0 ..< 13 { state.units[slot].route[i] = state.units[slot].route[i + 1] }
        state.units[slot].route[13] = 0xFF
        return 1
    }
}
