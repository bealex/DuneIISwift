/// A single explosion command. A port of OpenDUNE's `ExplosionCommand` (`src/explosion.h`).
public enum ExplosionCommand: UInt8, Sendable, Equatable {
    case stop = 0             // stop the explosion + free the slot
    case setSprite = 1        // param: new sprite id
    case setTimeout = 2       // param: ticks until the next command
    case setRandomTimeout = 3 // param: max ticks (a uniform LCG draw 0…param)
    case moveYPosition = 4    // param: signed pixels to shift the y position
    case tileDamage = 5       // crater/spice/bloom (seam; see GameState+Explosion)
    case playVoice = 6        // param: voice id (audio seam)
    case screenShake = 7      // video seam
    case setAnimation = 8     // param: map-animation id (seam; crash explosions only)
    case bloomExplosion = 9   // detonate a spice bloom under the tile (seam)
}

/// One `(command, parameter)` step. A port of `ExplosionCommandStruct` (`src/explosion.h`). `parameter`
/// is `Int16` so `MOVE_Y_POSITION -80` is natural.
public struct ExplosionCommandStruct: Sendable, Equatable {
    public let command: ExplosionCommand
    public let parameter: Int16
    public init(_ command: ExplosionCommand, _ parameter: Int16) { self.command = command; self.parameter = parameter }
}

/// The explosion types. A port of OpenDUNE's `ExplosionType` (`src/explosion.h`); the raw value indexes
/// `ExplosionTables.commands`. `structure` (14) is the building-destruction explosion.
public enum ExplosionType: Int, Sendable, Equatable {
    case impactSmall = 0
    case impactMedium = 1
    case impactLarge = 2
    case impactExplode = 3
    case saboteurDeath = 4
    case saboteurInfiltrate = 5
    case tankExplode = 6
    case deviatorGas = 7
    case sandBurst = 8
    case tankFlames = 9
    case wheeledVehicle = 10
    case deathHand = 11
    case unused12 = 12
    case sandwormSwallow = 13
    case structure = 14
    case smokePlume = 15
    case ornithopterCrash = 16
    case carryallCrash = 17
    case miniRocket = 18
    case spiceBloomTremor = 19

    public static let max = 20
}

/// An active explosion instance. A port of OpenDUNE's `Explosion` (`src/explosion.c`); lives in the
/// `GameState.explosions` pool. `tableIndex` is the `ExplosionType.rawValue` whose command list it runs
/// (`tableIndex < 0` / `active == false` means a free slot, mirroring C's `commands == NULL`).
public struct Explosion: Sendable, Equatable {
    public var timeOut: UInt32 = 0
    public var houseID: UInt8 = 0
    public var current: UInt8 = 0      // cursor into the command list
    public var spriteID: UInt16 = 0
    public var tableIndex: Int = -1    // ExplosionType.rawValue, or -1 for a free slot
    public var position: Tile32 = Tile32(x: 0, y: 0)
    public var active = false
    public init() {}
}

private func e(_ command: ExplosionCommand, _ parameter: Int16) -> ExplosionCommandStruct {
    ExplosionCommandStruct(command, parameter)
}

/// The explosion command tables — a verbatim port of `g_table_explosion` (`src/table/explosion.c`), one
/// list per `ExplosionType` (indexed by its raw value). The long flame/smoke tails repeat a fixed cycle
/// (written with a loop for readability; the produced lists are identical to the C tables).
public enum ExplosionTables {
    public static let commands: [[ExplosionCommandStruct]] = [
        /* 00 impactSmall */
        [ e(.setSprite, 153), e(.setTimeout, 3), e(.bloomExplosion, 0), e(.setSprite, 153), e(.setTimeout, 3), e(.stop, 0) ],
        /* 01 impactMedium */
        [ e(.setSprite, 154), e(.bloomExplosion, 0), e(.setTimeout, 3), e(.setSprite, 153), e(.setTimeout, 3), e(.setSprite, 154), e(.setTimeout, 3), e(.stop, 0) ],
        /* 02 impactLarge */
        [ e(.setSprite, 183), e(.playVoice, 50), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 15), e(.setSprite, 184), e(.setTimeout, 15), e(.stop, 0) ],
        /* 03 impactExplode */
        [ e(.setSprite, 183), e(.playVoice, 49), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 3), e(.setSprite, 184), e(.setTimeout, 3), e(.stop, 0) ],
        /* 04 saboteurDeath */
        [ e(.setSprite, 203), e(.playVoice, 51), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 7),
          e(.setSprite, 204), e(.setTimeout, 3), e(.setSprite, 205), e(.setTimeout, 3), e(.setSprite, 206), e(.setTimeout, 3), e(.setSprite, 207), e(.setTimeout, 3), e(.stop, 0) ],
        /* 05 saboteurInfiltrate */
        [ e(.setRandomTimeout, 60), e(.setSprite, 203), e(.playVoice, 41), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 7),
          e(.setSprite, 204), e(.setTimeout, 3), e(.setSprite, 205), e(.setTimeout, 3), e(.setSprite, 206), e(.setTimeout, 3), e(.setSprite, 207), e(.setTimeout, 3), e(.stop, 0) ],
        /* 06 tankExplode */
        [ e(.setSprite, 198), e(.playVoice, 51), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 7),
          e(.setSprite, 199), e(.setTimeout, 3), e(.setSprite, 200), e(.setTimeout, 3), e(.setSprite, 201), e(.setTimeout, 3), e(.setSprite, 202), e(.setTimeout, 3), e(.stop, 0) ],
        /* 07 deviatorGas */
        [ e(.setSprite, 208), e(.playVoice, 39), e(.setTimeout, 15), e(.setSprite, 209), e(.setTimeout, 15), e(.setSprite, 210), e(.setTimeout, 15),
          e(.setSprite, 211), e(.setTimeout, 15), e(.setSprite, 212), e(.setTimeout, 15), e(.stop, 0) ],
        /* 08 sandBurst */
        [ e(.setSprite, 156), e(.playVoice, 40), e(.bloomExplosion, 0), e(.setTimeout, 7), e(.setSprite, 157), e(.setTimeout, 3),
          e(.setSprite, 158), e(.setTimeout, 3), e(.setSprite, 157), e(.setTimeout, 3), e(.tileDamage, 0), e(.stop, 0) ],
        /* 09 tankFlames */
        [ e(.setSprite, 183), e(.playVoice, 41), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 3),
          e(.setSprite, 203), e(.setTimeout, 3), e(.moveYPosition, -80) ]
            + (0 ..< 5).flatMap { _ in [ e(.setSprite, 168), e(.setTimeout, 15), e(.setSprite, 169), e(.setTimeout, 15), e(.setSprite, 170), e(.setTimeout, 15) ] }
            + [ e(.stop, 0) ],
        /* 10 wheeledVehicle */
        [ e(.setSprite, 151), e(.playVoice, 49), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 7), e(.setSprite, 152), e(.setTimeout, 7), e(.stop, 0) ],
        /* 11 deathHand */
        [ e(.setRandomTimeout, 60), e(.setSprite, 188), e(.playVoice, 51), e(.bloomExplosion, 0), e(.tileDamage, 0), e(.setTimeout, 7),
          e(.setSprite, 189), e(.setTimeout, 3), e(.setSprite, 190), e(.setTimeout, 3), e(.setSprite, 191), e(.setTimeout, 3), e(.setSprite, 192), e(.setTimeout, 3), e(.stop, 0) ],
        /* 12 unused12 */
        [ e(.setSprite, 213), e(.setTimeout, 15), e(.setSprite, 214), e(.setTimeout, 15), e(.setSprite, 215), e(.setTimeout, 15),
          e(.setSprite, 216), e(.setTimeout, 15), e(.setSprite, 217), e(.setTimeout, 30), e(.stop, 0) ],
        /* 13 sandwormSwallow */
        [ e(.setSprite, 218), e(.setTimeout, 15), e(.setSprite, 219), e(.setTimeout, 15), e(.setSprite, 220), e(.setTimeout, 15),
          e(.setSprite, 221), e(.setTimeout, 15), e(.setSprite, 222), e(.setTimeout, 30), e(.stop, 0) ],
        /* 14 structure */
        [ e(.setRandomTimeout, 60), e(.setSprite, 188), e(.playVoice, 51), e(.setTimeout, 7), e(.setSprite, 189), e(.bloomExplosion, 0), e(.screenShake, 0),
          e(.setTimeout, 3), e(.setSprite, 190), e(.setTimeout, 3), e(.setSprite, 191), e(.setTimeout, 3), e(.setSprite, 192), e(.setTimeout, 3), e(.stop, 0) ],
        /* 15 smokePlume */
        [ e(.setSprite, 183), e(.playVoice, 49), e(.moveYPosition, -80), e(.setTimeout, 3), e(.setSprite, 184), e(.setTimeout, 3) ]
            + (0 ..< 6).flatMap { _ in [ e(.setSprite, 180), e(.setTimeout, 15), e(.setSprite, 181), e(.setTimeout, 15), e(.setSprite, 182), e(.setTimeout, 15), e(.setSprite, 181), e(.setTimeout, 15) ] }
            + [ e(.stop, 0) ],
        /* 16 ornithopterCrash */
        [ e(.setSprite, 203), e(.playVoice, 49), e(.bloomExplosion, 0), e(.setAnimation, 0), e(.setTimeout, 3), e(.setSprite, 204), e(.setSprite, 207), e(.setTimeout, 3), e(.stop, 0) ],
        /* 17 carryallCrash */
        [ e(.setSprite, 203), e(.playVoice, 49), e(.bloomExplosion, 0), e(.setAnimation, 4), e(.setTimeout, 3), e(.setSprite, 204), e(.setSprite, 207), e(.setTimeout, 3), e(.stop, 0) ],
        /* 18 miniRocket */
        [ e(.setSprite, 183), e(.playVoice, 54), e(.bloomExplosion, 0), e(.setTimeout, 3), e(.setSprite, 184), e(.setTimeout, 3), e(.stop, 0) ],
        /* 19 spiceBloomTremor */
        [ e(.setSprite, 156), e(.playVoice, 40), e(.screenShake, 0), e(.setTimeout, 7), e(.screenShake, 0), e(.setSprite, 157), e(.setTimeout, 3),
          e(.screenShake, 0), e(.setSprite, 158), e(.setTimeout, 3), e(.screenShake, 0), e(.setSprite, 157), e(.setTimeout, 3), e(.screenShake, 0), e(.tileDamage, 0), e(.stop, 0) ],
    ]
}
