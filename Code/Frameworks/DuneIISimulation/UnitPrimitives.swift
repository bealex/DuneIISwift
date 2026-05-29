import DuneIIContracts
import DuneIIWorld

/// The replaceable seam for the native per-unit primitives ported from OpenDUNE `src/unit.c`. Each
/// mutates a single `Unit` in place and matches its OpenDUNE function by result/effect (the unit's own
/// state). `Simulation` holds an injected instance, so the implementation can be swapped — e.g. a
/// reference vs. an optimized port, an instrumented/decision-tracing variant, or a test double — which
/// static functions could not provide.
public protocol UnitPrimitives: Sendable {
    /// `Unit_SetOrientation` (`unit.c:1671`): aim orientation slot `level` (0 = base, 1 = turret) at
    /// `orientation`, choosing the shorter turn direction. `rotateInstantly` snaps with no turn.
    func setOrientation(_ unit: inout Unit, orientation: Int8, rotateInstantly: Bool, level: Int)

    /// `Unit_Rotate` (`unit.c:65`): step orientation slot `level` toward its target by its rotation
    /// speed, snapping (and stopping) once it would reach/overshoot the target.
    func rotate(_ unit: inout Unit, level: Int)

    /// `Unit_SetSpeed` (`unit.c:1902`): set the per-tick movement speed from a 0…255 `speed` request,
    /// scaled by the type's `movingSpeedFactor`, the harvester's spice load, and (non-air) `gameSpeed`.
    func setSpeed(_ unit: inout Unit, speed: UInt16, gameSpeed: UInt16)

    /// `Unit_IsValidMovementIntoStructure` (`unit.c:660`): can `unit` move into `structure`?
    /// `0` = no, `1` = move onto / close, `2` = actually enter. Read-only.
    func isValidMovementIntoStructure(_ unit: Unit, _ structure: Structure, in state: GameState) -> UInt16

    /// `Unit_GetTileEnterScore` (`unit.c:2335`): the cost of `unit` entering tile `packed` arriving
    /// along `orient8`. `256` = inaccessible, `-1`/`-2` = an accessible structure, otherwise an
    /// inverted-speed estimate (lower = faster). Read-only; composes the map + house primitives.
    func tileEnterScore(_ unit: Unit, packed: UInt16, orient8: UInt16, in state: GameState,
                        map: any MapPrimitives, house: any HousePrimitives) -> Int16
}

/// The OpenDUNE-faithful implementation of `UnitPrimitives`. Stateless; the default the `Simulation`
/// uses unless another is injected.
public struct DefaultUnitPrimitives: UnitPrimitives {
    public init() {}

    public func setOrientation(_ unit: inout Unit, orientation: Int8, rotateInstantly: Bool, level: Int) {
        unit.orientation[level].speed = 0
        unit.orientation[level].target = orientation

        if rotateInstantly {
            unit.orientation[level].current = orientation
            return
        }
        if unit.orientation[level].current == orientation { return }
        guard let type = UnitType(rawValue: Int(unit.o.type)) else { return }

        unit.orientation[level].speed = Int8(truncatingIfNeeded: Int(UnitInfo[type].turningSpeed) * 4)

        let diff = Int(orientation) - Int(unit.orientation[level].current)
        if (diff > -128 && diff < 0) || diff > 128 {
            unit.orientation[level].speed = Int8(truncatingIfNeeded: -Int(unit.orientation[level].speed))
        }
    }

    /// OpenDUNE then calls `Unit_UpdateMap(2, …)` when the rendered orientation bucket changes; that is
    /// render dirty-marking + visibility house-counts (the Tier-D map cluster) and does not change the
    /// unit's own state, which is what this primitive's parity asserts — so it is deferred to Tier D.
    public func rotate(_ unit: inout Unit, level: Int) {
        if unit.orientation[level].speed == 0 { return }

        let target = Int(unit.orientation[level].target)
        let current = Int(unit.orientation[level].current)
        var diff = target - current
        if diff > 128 { diff -= 256 }
        if diff < -128 { diff += 256 }
        diff = abs(diff)

        var newCurrent = current + Int(unit.orientation[level].speed)
        if abs(Int(unit.orientation[level].speed)) >= diff {
            unit.orientation[level].speed = 0
            newCurrent = target
        }
        unit.orientation[level].current = Int8(truncatingIfNeeded: newCurrent)
    }

    public func setSpeed(_ unit: inout Unit, speed rawSpeed: UInt16, gameSpeed: UInt16) {
        unit.speed = 0
        unit.speedRemainder = 0
        unit.speedPerTick = 0

        guard let type = UnitType(rawValue: Int(unit.o.type)) else { return }
        let info = UnitInfo[type]

        var speed = rawSpeed
        if type == .harvester {
            speed = UInt16((Int(255 - Int(unit.amount)) * Int(speed)) / 256)
        }

        if speed == 0 || speed >= 256 {
            unit.movingSpeed = 0
            return
        }

        unit.movingSpeed = UInt8(speed & 0xFF)
        speed = UInt16(UInt32(info.movingSpeedFactor) * UInt32(speed) / 256)

        // Units in the air don't feel the effect of gameSpeed.
        if info.movementType != .winger {
            speed = Tools.adjustToGameSpeed(normal: speed, minimum: 1, maximum: 255,
                                            inverseSpeed: false, gameSpeed: gameSpeed)
        }

        var speedPerTick = speed << 4
        speed = speed >> 4
        if speed != 0 {
            speedPerTick = 255
        } else {
            speed = 1
        }

        unit.speed = UInt8(speed & 0xFF)
        unit.speedPerTick = UInt8(speedPerTick & 0xFF)
    }

    public func isValidMovementIntoStructure(_ unit: Unit, _ s: Structure, in state: GameState) -> UInt16 {
        guard let st = StructureType(rawValue: Int(s.o.type)),
              let ut = UnitType(rawValue: Int(unit.o.type)) else { return 0 }
        let si = StructureInfo[st]
        let ui = UnitInfo[ut]

        let unitEnc = state.indexEncode(unit.o.index, type: .unit)
        let structEnc = state.indexEncode(s.o.index, type: .structure)

        // Movement into a structure of another owner.
        if state.unitHouseID(unit) != s.o.houseID {
            // Saboteurs can always enter houses.
            if ut == .saboteur && unit.targetMove == structEnc { return 2 }
            // Otherwise only foot-units may enter a conquerable structure; everyone else moves close.
            if ui.movementType == .foot && si.o.flags.contains(.conquerable) {
                return unit.targetMove == structEnc ? 2 : 1
            }
            return 0
        }

        // Prevent movement if the target structure does not accept the unit type.
        if (si.enterFilter & (UInt32(1) << UInt32(unit.o.type))) == 0 { return 0 }

        // TODO -- Not sure. (transcribed verbatim from OpenDUNE.)
        if s.o.script.variables[4] == unitEnc { return 2 }

        // Enter only if the structure is not already linked to another unit.
        return s.o.linkedID == 0xFF ? 1 : 0
    }

    public func tileEnterScore(_ unit: Unit, packed: UInt16, orient8: UInt16, in state: GameState,
                               map: any MapPrimitives, house: any HousePrimitives) -> Int16 {
        guard let ut = UnitType(rawValue: Int(unit.o.type)) else { return 0 }
        let ui = UnitInfo[ut]

        if !map.isValidPosition(packed, mapScale: state.mapScale) && ui.movementType != .winger {
            return 256
        }

        if let slot = state.unitGetByPackedTile(packed) {
            let u = state.units[slot]
            if u.o.index != unit.o.index && ut != .sandworm {
                if ut == .saboteur && unit.targetMove == state.indexEncode(u.o.index, type: .unit) {
                    return 0
                }
                if house.areAllied(state.unitHouseID(u), state.unitHouseID(unit),
                                   playerHouseID: state.playerHouseID) {
                    return 256
                }
                let occupantMt = (UnitType(rawValue: Int(u.o.type)).map { UnitInfo[$0].movementType }) ?? .foot
                if occupantMt != .foot || (ui.movementType != .tracked && ui.movementType != .harvester) {
                    return 256
                }
            }
        }

        if let sslot = state.structureGetByPackedTile(packed) {
            let res = isValidMovementIntoStructure(unit, state.structures[sslot], in: state)
            if res == 0 { return 256 }
            return Int16(-Int(res))
        }

        let type = map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        var res = UInt16(LandscapeInfo[type].speed(ui.movementType))

        if ut == .saboteur && type == .wall {
            if !house.areAllied(state.map[Int(packed)].houseID, state.unitHouseID(unit),
                                playerHouseID: state.playerHouseID) {
                res = 255
            }
        }

        if res == 0 { return 256 }

        // Diagonal travel is cheaper per tile.
        if (orient8 & 1) != 0 {
            res -= res / 4 + res / 8
        }

        // 'Invert' the speed to get a rough estimate of the time taken.
        res ^= 0xFF

        return Int16(res)
    }
}
