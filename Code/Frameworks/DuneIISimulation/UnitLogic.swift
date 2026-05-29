import DuneIIContracts
import DuneIIWorld

/// Native per-unit primitives ported from OpenDUNE `src/unit.c`. Each mutates a single `Unit` in
/// place and matches its OpenDUNE function by result/effect (the unit's own state). They take an
/// `inout Unit` so they compose with `GameState.units[i]`.
public enum UnitLogic {
    /// `Unit_SetOrientation` (`unit.c:1671`): aim orientation slot `level` (0 = base, 1 = turret) at
    /// `orientation`, choosing the shorter turn direction. `rotateInstantly` snaps with no turn.
    public static func setOrientation(
        _ unit: inout Unit, orientation: Int8, rotateInstantly: Bool, level: Int
    ) {
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

    /// `Unit_Rotate` (`unit.c:65`): step orientation slot `level` toward its target by its rotation
    /// speed, snapping (and stopping) once it would reach/overshoot the target.
    ///
    /// OpenDUNE then calls `Unit_UpdateMap(2, …)` when the rendered orientation bucket changes; that is
    /// render dirty-marking + visibility house-counts (the Tier-D map cluster) and does not change the
    /// unit's own state, which is what this primitive's parity asserts — so it is deferred to Tier D.
    public static func rotate(_ unit: inout Unit, level: Int) {
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

    /// `Unit_SetSpeed` (`unit.c:1902`): set the per-tick movement speed from a 0…255 `speed` request,
    /// scaled by the type's `movingSpeedFactor`, the harvester's spice load, and (for non-air units)
    /// the game speed.
    public static func setSpeed(_ unit: inout Unit, speed rawSpeed: UInt16, gameSpeed: UInt16) {
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
}
