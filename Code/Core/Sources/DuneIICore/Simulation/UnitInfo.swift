import Foundation

extension Simulation {
    /// `DisplayMode` enum matching OpenDUNE's `DisplayMode` in
    /// `src/unit.h` — chooses the orientation→frame-index scheme used by
    /// `Map_DrawUnit` when rendering a unit's SHP.
    public enum DisplayMode: UInt8, Sendable {
        /// Standard ground / rocket: 5 distinct frames across 8 orientations,
        /// three of them mirrored horizontally (values_32A4).
        case unit        = 0
        case ornithopter = 1
        /// Foot soldiers with 3 walk frames: 3-cycle animation × 3 direction buckets.
        case infantry3   = 2
        /// Foot soldiers with 4 walk frames: 4-cycle animation × 3 direction buckets.
        case infantry4   = 3
        case rocket      = 4
        case singleFrame = 5
    }

    /// Movement-type enum matching OpenDUNE's `MovementType` in `src/unit.h`.
    public enum MovementType: UInt8, Sendable {
        case foot        = 0
        case tracked     = 1
        case harvester   = 2
        case wheeled     = 3
        case winger      = 4
        case slither     = 5
    }

    /// Unit action IDs matching OpenDUNE's `ActionType` in `src/unit.h`.
    /// We keep them as raw `UInt8` on slots and use this enum only for
    /// table-definition readability.
    public enum ActionID {
        public static let attack: UInt8 = 0
        public static let move: UInt8 = 1
        public static let retreat: UInt8 = 2
        public static let guard_: UInt8 = 3
        public static let areaGuard: UInt8 = 4
        public static let harvest: UInt8 = 5
        public static let returnAction: UInt8 = 6
        public static let stop: UInt8 = 7
        public static let ambush: UInt8 = 8
        public static let sabotage: UInt8 = 9
        public static let die: UInt8 = 10
        public static let hunt: UInt8 = 11
        public static let deploy: UInt8 = 12
        public static let destruct: UInt8 = 13
    }

    /// Per-unit-type stats. Trimmed to the fields our wired host functions
    /// and the naive movement step read; the full OpenDUNE `UnitInfo`
    /// structure (~40 fields) isn't needed until P5 production / combat
    /// land. Source: `src/table/unitinfo.c` — every row hand-extracted via
    /// the Dune II 1.07 tables, verified row-by-row.
    public struct UnitInfo: Sendable, Equatable {
        public let hitpoints: UInt16
        public let fireDistance: UInt16
        public let fireDelay: UInt16
        public let damage: UInt16
        public let movementType: MovementType
        public let hasTurret: Bool
        public let explodeOnDeath: Bool
        public let movingSpeedFactor: UInt16
        public let turningSpeed: UInt8
        /// 4-entry `actionsPlayer` array: the 4 GUI buttons presented to
        /// human controllers. `actionsPlayer[3]` is the "default" action
        /// used by `Script_Unit_SetActionDefault`.
        public let actionsPlayer: [UInt8]
        /// AI default action when the unit spawns / idles.
        public let actionAI: UInt8
        /// Base sprite index into the concatenated global sprite array
        /// (see `Sprites_Load` in `src/sprites.c:487`). Orientation ticks
        /// add 0..4 frames via `values_32A4`. Pair with `displayMode` to
        /// pick the right offset scheme.
        public let groundSpriteID: UInt16
        public let displayMode: DisplayMode
        /// `ObjectInfo.flags.priority` — when `false`, this unit is never
        /// considered as an attack target. Bullets, missiles, sonic blasts
        /// all have `priority = false`.
        public let priority: Bool
        /// `ObjectInfo.flags.targetAir` — when `true`, this unit can aim at
        /// air units (`MovementType.winger`). Only two units in vanilla
        /// have it: TROOPERS (3) and LAUNCHER (7), plus TROOPER (5).
        public let targetAir: Bool
        /// `ObjectInfo.priorityBuild` — AI-side "how badly we want to build
        /// one". Folded into target priority because `FindBestTarget` sums
        /// `build + target` (OpenDUNE rationale: a thing that's expensive to
        /// produce is also a juicy thing to shoot).
        public let priorityBuild: UInt16
        /// `ObjectInfo.priorityTarget` — "how badly someone wants to shoot
        /// this". Summed with `priorityBuild` in priority math.
        public let priorityTarget: UInt16
        /// Inclusive lower bound of the pool-index range `Unit_Allocate`
        /// uses when `index == UNIT_INDEX_INVALID`. Dune II's unit types
        /// share a single 102-slot `UnitPool`; bullets sit at 12..15,
        /// sandworms at 16..17, vehicles at 22..101, etc. See `Fire.md` §1.
        public let indexStart: UInt16
        /// Inclusive upper bound of the pool-index range. See `indexStart`.
        public let indexEnd: UInt16
        /// Bullet spawned by `Script_Unit_Fire`. `nil` for non-firing types
        /// (carryall, harvester, MCV, bullets themselves) — matches
        /// OpenDUNE's `UNIT_INVALID = 0xFF` sentinel.
        public let bulletType: UInt8?
        /// `ObjectInfo.flags.firesTwice` — double-tap weapons (TANK,
        /// SIEGE_TANK, QUAD, DEVASTATOR, RAIDER_TRIKE, LAUNCHER,
        /// ORNITHOPTER). When true and HP > maxHP/2, every other shot
        /// uses the 5-tick quick reload.
        public let firesTwice: Bool
        /// Explosion this unit's bullet creates on impact (`src/table/unitinfo.c`
        /// `/* explosionType */`). Also used by `explodeOnDeath` units
        /// when they die (deferred wiring). `nil` → no explosion
        /// (`EXPLOSION_INVALID = 0xFFFF`).
        public let explosionType: UInt16?

        public static let table: [UnitInfo] = [
            // 0 CARRYALL
            UnitInfo(hitpoints: 100, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 3,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 283, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 20, priorityTarget: 16,
                     indexStart: 0, indexEnd: 10, bulletType: nil, firesTwice: false,
                     explosionType: nil),
            // 1 ORNITHOPTER
            UnitInfo(hitpoints: 25, fireDistance: 50, fireDelay: 50, damage: 50,
                     movementType: .winger, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 150, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 289, displayMode: .ornithopter,
                     priority: true, targetAir: false, priorityBuild: 75, priorityTarget: 30,
                     indexStart: 0, indexEnd: 10, bulletType: 22, firesTwice: true,
                     explosionType: 0),
            // 2 INFANTRY (squad)
            UnitInfo(hitpoints: 50, fireDistance: 2, fireDelay: 45, damage: 3,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 5, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 329, displayMode: .infantry4,
                     priority: true, targetAir: false, priorityBuild: 20, priorityTarget: 20,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0),
            // 3 TROOPERS (squad)
            UnitInfo(hitpoints: 110, fireDistance: 5, fireDelay: 50, damage: 5,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 10, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 341, displayMode: .infantry4,
                     priority: true, targetAir: true, priorityBuild: 50, priorityTarget: 50,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0),
            // 4 SOLDIER
            UnitInfo(hitpoints: 20, fireDistance: 2, fireDelay: 45, damage: 3,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 8, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 311, displayMode: .infantry3,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 10,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 0),
            // 5 TROOPER
            UnitInfo(hitpoints: 45, fireDistance: 5, fireDelay: 50, damage: 5,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 15, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 320, displayMode: .infantry3,
                     priority: true, targetAir: true, priorityBuild: 20, priorityTarget: 30,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 0),
            // 6 SABOTEUR
            UnitInfo(hitpoints: 10, fireDistance: 2, fireDelay: 45, damage: 2,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 40, turningSpeed: 3,
                     actionsPlayer: [ActionID.sabotage, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 301, displayMode: .infantry3,
                     priority: true, targetAir: false, priorityBuild: 0, priorityTarget: 700,
                     indexStart: 20, indexEnd: 21, bulletType: 23, firesTwice: false,
                     explosionType: 0),
            // 7 LAUNCHER
            UnitInfo(hitpoints: 100, fireDistance: 9, fireDelay: 120, damage: 75,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: true, priorityBuild: 100, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: 19, firesTwice: true,
                     explosionType: 3),
            // 8 DEVIATOR
            UnitInfo(hitpoints: 120, fireDistance: 7, fireDelay: 180, damage: 0,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 50, priorityTarget: 175,
                     indexStart: 22, indexEnd: 101, bulletType: 21, firesTwice: false,
                     explosionType: 3),
            // 9 TANK
            UnitInfo(hitpoints: 200, fireDistance: 4, fireDelay: 80, damage: 25,
                     movementType: .tracked, hasTurret: true, explodeOnDeath: true,
                     movingSpeedFactor: 25, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 80, priorityTarget: 100,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 1),
            // 10 SIEGE_TANK
            UnitInfo(hitpoints: 300, fireDistance: 5, fireDelay: 90, damage: 30,
                     movementType: .tracked, hasTurret: true, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 121, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 130, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 1),
            // 11 DEVASTATOR
            UnitInfo(hitpoints: 400, fireDistance: 5, fireDelay: 100, damage: 40,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 10, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.destruct, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 131, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 175, priorityTarget: 180,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 1),
            // 12 SONIC_TANK
            UnitInfo(hitpoints: 110, fireDistance: 8, fireDelay: 80, damage: 60,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 80, priorityTarget: 110,
                     indexStart: 22, indexEnd: 101, bulletType: 24, firesTwice: false,
                     explosionType: nil),
            // 13 TRIKE
            UnitInfo(hitpoints: 100, fireDistance: 3, fireDelay: 50, damage: 5,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 45, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 243, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 50, priorityTarget: 50,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0),
            // 14 RAIDER_TRIKE
            UnitInfo(hitpoints: 80, fireDistance: 3, fireDelay: 50, damage: 5,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 60, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 243, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 55, priorityTarget: 60,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0),
            // 15 QUAD
            UnitInfo(hitpoints: 130, fireDistance: 3, fireDelay: 50, damage: 7,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 40, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 238, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 60, priorityTarget: 60,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0),
            // 16 HARVESTER
            UnitInfo(hitpoints: 150, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .harvester, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.harvest, ActionID.move, ActionID.returnAction, ActionID.stop],
                     actionAI: ActionID.harvest,
                     groundSpriteID: 248, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: nil, firesTwice: false,
                     explosionType: nil),
            // 17 MCV
            UnitInfo(hitpoints: 150, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.deploy, ActionID.move, ActionID.retreat, ActionID.stop],
                     actionAI: ActionID.move,
                     groundSpriteID: 253, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: nil, firesTwice: false,
                     explosionType: nil),
            // 18 MISSILE_HOUSE
            UnitInfo(hitpoints: 70, fireDistance: 15, fireDelay: 0, damage: 100,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 250, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 278, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 11),  // DEATH_HAND
            // 19 MISSILE_ROCKET
            UnitInfo(hitpoints: 70, fireDistance: 8, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 3),  // IMPACT_EXPLODE
            // 20 MISSILE_TURRET
            UnitInfo(hitpoints: 70, fireDistance: 60, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 160, turningSpeed: 8,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 3),  // IMPACT_EXPLODE
            // 21 MISSILE_DEVIATOR
            UnitInfo(hitpoints: 70, fireDistance: 7, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 7),  // DEVIATOR_GAS
            // 22 MISSILE_TROOPER
            UnitInfo(hitpoints: 70, fireDistance: 3, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 180, turningSpeed: 5,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 268, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 18),  // MINI_ROCKET
            // 23 BULLET
            UnitInfo(hitpoints: 1, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 250, turningSpeed: 0,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 174, displayMode: .singleFrame,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 0),  // IMPACT_SMALL
            // 24 SONIC_BLAST
            UnitInfo(hitpoints: 1, fireDistance: 10, fireDelay: 0, damage: 25,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 0,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 160, displayMode: .singleFrame,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: nil),  // EXPLOSION_INVALID (propagates as beam)
            // 25 SANDWORM
            UnitInfo(hitpoints: 1000, fireDistance: 0, fireDelay: 20, damage: 300,
                     movementType: .slither, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 35, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.attack, ActionID.attack, ActionID.attack],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 161, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 16, indexEnd: 17, bulletType: 25, firesTwice: false,
                     explosionType: 13),  // SANDWORM_SWALLOW
            // 26 FRIGATE
            UnitInfo(hitpoints: 100, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 130, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 298, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 11, indexEnd: 11, bulletType: nil, firesTwice: false,
                     explosionType: nil)
        ]

        public static func lookup(_ type: UInt8) -> UnitInfo? {
            let i = Int(type)
            guard i >= 0, i < table.count else { return nil }
            return table[i]
        }
    }
}
