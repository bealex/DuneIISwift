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
        /// `ACTION_INVALID` (`src/unit.h:99`) — used as the `actionAI`
        /// for bullets, missiles, sandworms, and the frigate. When
        /// `Unit_SetAction` is called with this value it early-returns
        /// (`src/unit.c:502`), so freshly-created units of those types
        /// keep the `ACTION_GUARD` default `Unit_Create` writes at
        /// `src/unit.c:425`.
        public static let invalid: UInt8 = 0xFF

        /// Port of `g_table_actionInfo[action].switchType`
        /// (`src/table/actioninfo.c`). 0 for actions that defer the
        /// reset until `currentDestination` reaches `(0, 0)`; 1 for
        /// hard-reset actions (DIE, DESTRUCT); 2 isn't used in the
        /// 1.07 table. Read by `Unit_SetAction`'s switch
        /// (`src/unit.c:506..529`) and by the Swift port in
        /// `Scripting.Functions.makeSetActionUnit`.
        public static func switchType(action: UInt8) -> UInt8 {
            switch action {
            case die, destruct: return 1
            default: return 0
            }
        }
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
        /// Sprite-animation pace. Port of OpenDUNE `animationSpeed`
        /// (`src/unit.h:196`). Used by `tickUnknown5` at
        /// `src/unit.c:248` to compute the per-animation pause:
        /// `u->timer = animationSpeed / 5` (or 4 for harvester / 3 for
        /// isSmoking / 1 for ornithopter). Zero means "no walking
        /// animation" (bullets, MCV, sandworm, etc.).
        public let animationSpeed: UInt16
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
        /// `UnitInfo.flags.mustStayInMap` — true for CARRYALL + ORNITHOPTER
        /// (rows 0 and 1 in `src/table/unitinfo.c`). When a winger's
        /// next step would leave the 64×64 map, `Unit_Move`
        /// (`src/unit.c:1305..1317`) either:
        ///   - `!mustStayInMap` → `Unit_Remove` (used by bullets /
        ///     fremen / sandworm / save-initial escort flights),
        ///   - `mustStayInMap && byScenario && linkedID==0xFF &&
        ///     scriptVariables[4]==0` → `Unit_Remove` too (idle
        ///     save-initial escort carryall / ornithopter),
        ///   - else → bounce (random new orientation, position held).
        /// Without the port, wingers would fly forever off-map in Swift
        /// while OpenDUNE frees them — surfaces as SAVE007 tick 367
        /// `house[1].unitCount=6 vs 7` (u0 CARRYALL leaves the east
        /// edge).
        public let mustStayInMap: Bool
        /// Explosion this unit's bullet creates on impact (`src/table/unitinfo.c`
        /// `/* explosionType */`). Also used by `explodeOnDeath` units
        /// when they die (deferred wiring). `nil` → no explosion
        /// (`EXPLOSION_INVALID = 0xFFFF`).
        public let explosionType: UInt16?
        /// `ObjectInfo.availableHouse`. `1 << houseID` bitmask of houses
        /// that can build this unit. Default `flagAll` (63) covers the
        /// "anyone can build this" majority — only rows that differ
        /// need to spell it out. Slice 5a.
        public let availableHouse: UInt8
        /// `ObjectInfo.structuresRequired`. Bitmask of structure type IDs
        /// that must already be in the owner's `structuresBuilt` before
        /// a factory may produce this unit. Non-zero for just four
        /// IX-gated units (Thopter, Deviator, Devastator, Sonic Tank).
        public let structuresRequired: UInt32
        /// `ObjectInfo.upgradeLevelRequired`. Minimum factory
        /// `upgradeLevel` to unlock this unit. Non-zero for 7 of 27
        /// rows (Thopter / Infantry / Troopers / Launcher / Siege Tank /
        /// Quad / MCV).
        public let upgradeLevelRequired: UInt8
        /// `ObjectInfo.buildTime`. Produced unit's build time in game
        /// ticks at standard buildSpeed = 256. Factory `startConstruction`
        /// uses this for `countDown = buildTime << 8`. Zero for
        /// projectiles / misc units that never appear in a factory's
        /// `buildableUnits` array. Slice 5b-build.
        public let buildTime: UInt16
        /// `ObjectInfo.buildCredits`. Total credit cost to produce this
        /// unit. Drained across `buildTime` ticks at
        /// `costPerTick = buildCredits / buildTime` (slice 6c).
        /// Zero for projectiles / misc. Refunded proportionally on
        /// `cancelConstruction`.
        public let buildCredits: UInt16

        public init(
            hitpoints: UInt16,
            fireDistance: UInt16,
            fireDelay: UInt16,
            damage: UInt16,
            movementType: MovementType,
            hasTurret: Bool,
            explodeOnDeath: Bool,
            movingSpeedFactor: UInt16,
            turningSpeed: UInt8,
            animationSpeed: UInt16 = 0,
            actionsPlayer: [UInt8],
            actionAI: UInt8,
            groundSpriteID: UInt16,
            displayMode: DisplayMode,
            priority: Bool,
            targetAir: Bool,
            priorityBuild: UInt16,
            priorityTarget: UInt16,
            indexStart: UInt16,
            indexEnd: UInt16,
            bulletType: UInt8?,
            firesTwice: Bool,
            explosionType: UInt16?,
            availableHouse: UInt8 = 0b0011_1111,
            structuresRequired: UInt32 = 0,
            upgradeLevelRequired: UInt8 = 0,
            buildTime: UInt16 = 0,
            buildCredits: UInt16 = 0,
            mustStayInMap: Bool = false
        ) {
            self.hitpoints = hitpoints
            self.fireDistance = fireDistance
            self.fireDelay = fireDelay
            self.damage = damage
            self.movementType = movementType
            self.hasTurret = hasTurret
            self.explodeOnDeath = explodeOnDeath
            self.movingSpeedFactor = movingSpeedFactor
            self.turningSpeed = turningSpeed
            self.animationSpeed = animationSpeed
            self.actionsPlayer = actionsPlayer
            self.actionAI = actionAI
            self.groundSpriteID = groundSpriteID
            self.displayMode = displayMode
            self.priority = priority
            self.targetAir = targetAir
            self.priorityBuild = priorityBuild
            self.priorityTarget = priorityTarget
            self.indexStart = indexStart
            self.indexEnd = indexEnd
            self.bulletType = bulletType
            self.firesTwice = firesTwice
            self.explosionType = explosionType
            self.availableHouse = availableHouse
            self.structuresRequired = structuresRequired
            self.upgradeLevelRequired = upgradeLevelRequired
            self.buildTime = buildTime
            self.buildCredits = buildCredits
            self.mustStayInMap = mustStayInMap
        }

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
                     explosionType: nil,
                     buildTime: 64, buildCredits: 800, mustStayInMap: true),
            // 1 ORNITHOPTER
            UnitInfo(hitpoints: 25, fireDistance: 50, fireDelay: 50, damage: 50,
                     movementType: .winger, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 150, turningSpeed: 2,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.stop,
                     groundSpriteID: 289, displayMode: .ornithopter,
                     priority: true, targetAir: false, priorityBuild: 75, priorityTarget: 30,
                     indexStart: 0, indexEnd: 10, bulletType: 22, firesTwice: true,
                     explosionType: 0,
                     availableHouse: 62, structuresRequired: 1 << 6, upgradeLevelRequired: 1,
                     buildTime: 96, buildCredits: 600, mustStayInMap: true),
            // 2 INFANTRY (squad)
            UnitInfo(hitpoints: 50, fireDistance: 2, fireDelay: 45, damage: 3,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 5, turningSpeed: 3,
                     animationSpeed: 15,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 329, displayMode: .infantry4,
                     priority: true, targetAir: false, priorityBuild: 20, priorityTarget: 20,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0,
                     availableHouse: 62, upgradeLevelRequired: 1,
                     buildTime: 32, buildCredits: 100),
            // 3 TROOPERS (squad)
            UnitInfo(hitpoints: 110, fireDistance: 5, fireDelay: 50, damage: 5,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 10, turningSpeed: 3,
                     animationSpeed: 15,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 341, displayMode: .infantry4,
                     priority: true, targetAir: true, priorityBuild: 50, priorityTarget: 50,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0,
                     availableHouse: 61, upgradeLevelRequired: 1,
                     buildTime: 56, buildCredits: 200),
            // 4 SOLDIER
            UnitInfo(hitpoints: 20, fireDistance: 2, fireDelay: 45, damage: 3,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 8, turningSpeed: 3,
                     animationSpeed: 12,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 311, displayMode: .infantry3,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 10,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 0,
                     availableHouse: 62,
                     buildTime: 32, buildCredits: 60),
            // 5 TROOPER
            UnitInfo(hitpoints: 45, fireDistance: 5, fireDelay: 50, damage: 5,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 15, turningSpeed: 3,
                     animationSpeed: 12,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 320, displayMode: .infantry3,
                     priority: true, targetAir: true, priorityBuild: 20, priorityTarget: 30,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 0,
                     availableHouse: 61,
                     buildTime: 56, buildCredits: 100),
            // 6 SABOTEUR
            UnitInfo(hitpoints: 10, fireDistance: 2, fireDelay: 45, damage: 2,
                     movementType: .foot, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 40, turningSpeed: 3,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.sabotage, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 301, displayMode: .infantry3,
                     priority: true, targetAir: false, priorityBuild: 0, priorityTarget: 700,
                     indexStart: 20, indexEnd: 21, bulletType: 23, firesTwice: false,
                     explosionType: 0,
                     availableHouse: 4,
                     buildTime: 48, buildCredits: 120),
            // 7 LAUNCHER
            UnitInfo(hitpoints: 100, fireDistance: 9, fireDelay: 120, damage: 75,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: true, priorityBuild: 100, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: 19, firesTwice: true,
                     explosionType: 3,
                     availableHouse: 59, upgradeLevelRequired: 2,
                     buildTime: 72, buildCredits: 450),
            // 8 DEVIATOR
            UnitInfo(hitpoints: 120, fireDistance: 7, fireDelay: 180, damage: 0,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 50, priorityTarget: 175,
                     indexStart: 22, indexEnd: 101, bulletType: 21, firesTwice: false,
                     explosionType: 3,
                     availableHouse: 4, structuresRequired: 1 << 6,
                     buildTime: 80, buildCredits: 750),
            // 9 TANK
            UnitInfo(hitpoints: 200, fireDistance: 4, fireDelay: 80, damage: 25,
                     movementType: .tracked, hasTurret: true, explodeOnDeath: true,
                     movingSpeedFactor: 25, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 80, priorityTarget: 100,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: false,
                     explosionType: 1,
                     buildTime: 64, buildCredits: 300),
            // 10 SIEGE_TANK
            UnitInfo(hitpoints: 300, fireDistance: 5, fireDelay: 90, damage: 30,
                     movementType: .tracked, hasTurret: true, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 121, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 130, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 1,
                     upgradeLevelRequired: 3,
                     buildTime: 96, buildCredits: 600),
            // 11 DEVASTATOR
            UnitInfo(hitpoints: 400, fireDistance: 5, fireDelay: 100, damage: 40,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 10, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.destruct, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 131, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 175, priorityTarget: 180,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 1,
                     availableHouse: 57, structuresRequired: 1 << 6,
                     buildTime: 104, buildCredits: 800),
            // 12 SONIC_TANK
            UnitInfo(hitpoints: 110, fireDistance: 8, fireDelay: 80, damage: 60,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 30, turningSpeed: 1,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 111, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 80, priorityTarget: 110,
                     indexStart: 22, indexEnd: 101, bulletType: 24, firesTwice: false,
                     explosionType: nil,
                     availableHouse: 58, structuresRequired: 1 << 6,
                     buildTime: 104, buildCredits: 600),
            // 13 TRIKE
            UnitInfo(hitpoints: 100, fireDistance: 3, fireDelay: 50, damage: 5,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 45, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 243, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 50, priorityTarget: 50,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0,
                     availableHouse: 58,
                     buildTime: 40, buildCredits: 150),
            // 14 RAIDER_TRIKE
            UnitInfo(hitpoints: 80, fireDistance: 3, fireDelay: 50, damage: 5,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 60, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 243, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 55, priorityTarget: 60,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0,
                     availableHouse: 60,
                     buildTime: 40, buildCredits: 150),
            // 15 QUAD
            UnitInfo(hitpoints: 130, fireDistance: 3, fireDelay: 50, damage: 7,
                     movementType: .wheeled, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 40, turningSpeed: 2,
                     actionsPlayer: [ActionID.attack, ActionID.move, ActionID.retreat, ActionID.guard_],
                     actionAI: ActionID.hunt,
                     groundSpriteID: 238, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 60, priorityTarget: 60,
                     indexStart: 22, indexEnd: 101, bulletType: 23, firesTwice: true,
                     explosionType: 0,
                     upgradeLevelRequired: 1,
                     buildTime: 48, buildCredits: 200),
            // 16 HARVESTER
            UnitInfo(hitpoints: 150, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .harvester, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.harvest, ActionID.move, ActionID.returnAction, ActionID.stop],
                     actionAI: ActionID.harvest,
                     groundSpriteID: 248, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: nil, firesTwice: false,
                     explosionType: nil,
                     buildTime: 64, buildCredits: 300),
            // 17 MCV
            UnitInfo(hitpoints: 150, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .tracked, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 20, turningSpeed: 1,
                     actionsPlayer: [ActionID.deploy, ActionID.move, ActionID.retreat, ActionID.stop],
                     actionAI: ActionID.move,
                     groundSpriteID: 253, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 10, priorityTarget: 150,
                     indexStart: 22, indexEnd: 101, bulletType: nil, firesTwice: false,
                     explosionType: nil,
                     upgradeLevelRequired: 1,
                     buildTime: 80, buildCredits: 900),
            // 18 MISSILE_HOUSE
            // `actionAI = ACTION_INVALID` here (and on every bullet /
            // missile / sandworm / frigate row below) mirrors
            // `src/table/unitinfo.c:1391` and the others of their
            // kind. `Unit_SetAction` early-returns on INVALID
            // (`src/unit.c:502`), so `Unit_Create`'s default
            // `actionID = ACTION_GUARD` at `src/unit.c:425` stays put
            // for AI-spawned bullets — the player arm instead picks
            // `actionsPlayer[3]` (= STOP) via the `Unit_Create` tail.
            UnitInfo(hitpoints: 70, fireDistance: 15, fireDelay: 0, damage: 100,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 250, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 278, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 11,
                     availableHouse: 1),  // DEATH_HAND — Harkonnen only
            // 19 MISSILE_ROCKET
            UnitInfo(hitpoints: 70, fireDistance: 8, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 2,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 3),  // IMPACT_EXPLODE
            // 20 MISSILE_TURRET
            UnitInfo(hitpoints: 70, fireDistance: 60, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 160, turningSpeed: 8,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 3),  // IMPACT_EXPLODE
            // 21 MISSILE_DEVIATOR
            UnitInfo(hitpoints: 70, fireDistance: 7, fireDelay: 0, damage: 75,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 2,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 258, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 7),  // DEVIATOR_GAS
            // 22 MISSILE_TROOPER
            UnitInfo(hitpoints: 70, fireDistance: 3, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 180, turningSpeed: 5,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 268, displayMode: .rocket,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 18),  // MINI_ROCKET
            // 23 BULLET
            UnitInfo(hitpoints: 1, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: true,
                     movingSpeedFactor: 250, turningSpeed: 0,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 174, displayMode: .singleFrame,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: 0),  // IMPACT_SMALL
            // 24 SONIC_BLAST
            UnitInfo(hitpoints: 1, fireDistance: 10, fireDelay: 0, damage: 25,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 200, turningSpeed: 0,
                     animationSpeed: 7,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 160, displayMode: .singleFrame,
                     priority: false, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 12, indexEnd: 15, bulletType: nil, firesTwice: false,
                     explosionType: nil),  // EXPLOSION_INVALID (propagates as beam)
            // 25 SANDWORM
            UnitInfo(hitpoints: 1000, fireDistance: 0, fireDelay: 20, damage: 300,
                     movementType: .slither, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 35, turningSpeed: 3,
                     actionsPlayer: [ActionID.attack, ActionID.attack, ActionID.attack, ActionID.attack],
                     actionAI: ActionID.invalid,
                     groundSpriteID: 161, displayMode: .unit,
                     priority: true, targetAir: false, priorityBuild: 0, priorityTarget: 0,
                     indexStart: 16, indexEnd: 17, bulletType: 25, firesTwice: false,
                     explosionType: 13,
                     availableHouse: 8),  // SANDWORM_SWALLOW — Fremen only
            // 26 FRIGATE
            UnitInfo(hitpoints: 100, fireDistance: 0, fireDelay: 0, damage: 0,
                     movementType: .winger, hasTurret: false, explodeOnDeath: false,
                     movingSpeedFactor: 130, turningSpeed: 2,
                     actionsPlayer: [ActionID.stop, ActionID.stop, ActionID.stop, ActionID.stop],
                     actionAI: ActionID.invalid,
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

        /// Port of the `scriptNoSlowdown` flag on each row of OpenDUNE's
        /// `g_table_unitInfo` (`src/table/unitinfo.c`). When `true`, the
        /// unit's EMC script runs a full `SCRIPT_UNIT_OPCODES_PER_TICK + 2 = 52`
        /// opcodes per unit-tick; when `false`, off-viewport units are
        /// capped at `3` opcodes per tick (`src/unit.c:292..294`). Extracted
        /// as a dense table here rather than a full column on `UnitInfo`
        /// to avoid touching 27 UnitInfo rows — flip the individual row if
        /// any of these values ever needs updating.
        /// `canWobble` flag per unit type. From `src/table/unitinfo.c`'s
        /// `canWobble` column. Only SOLDIER(4), TROOPER(5), TRIKE(13),
        /// RAIDER_TRIKE(14), QUAD(15) can wobble — all others are false.
        /// Used by `Unit_Move` (`src/unit.c:1322`) to gate the
        /// `wobbleIndex = Tools_Random_256() & 7` byte draw; load-bearing
        /// for RNG-stream parity.
        public static func canWobble(type: UInt8) -> Bool {
            switch type {
            case 4, 5, 13, 14, 15: return true
            default: return false
            }
        }

        public static func scriptNoSlowdown(type: UInt8) -> Bool {
            // Row order matches `src/table/unitinfo.c` 27-unit table.
            // Lines cited: 32, 105, 178, 251, 324, 397, 470, 543, 616,
            // 689, 762, 835, 908, 981, 1054, 1127, 1200, 1273, 1346,
            // 1419, 1492, 1565, 1638, 1711, 1784, 1857, 1930.
            switch type {
            case 0, 1, 6, 16, 18, 19, 20, 21, 22, 23, 24, 25, 26:
                return true   // CARRYALL, THOPTER, HARVESTER, MCV, bullet + projectile family
            default:
                return false  // everything else (ground combat + infantry)
            }
        }

        /// Decodes a bitmask (from `Structures.buildableUnitsFromFactory`)
        /// into an ordered list of UNIT type IDs. Ascending order; bits
        /// 27..31 are ignored (only IDs 0..26 are valid unit types).
        /// Mirrors `StructureInfo.buildableTypes` but for the unit side.
        public static func buildableUnitTypes(from mask: UInt32) -> [UInt8] {
            var result: [UInt8] = []
            for typeID in UInt8(0)..<UInt8(27) where (mask & (UInt32(1) << UInt32(typeID))) != 0 {
                result.append(typeID)
            }
            return result
        }
    }
}
