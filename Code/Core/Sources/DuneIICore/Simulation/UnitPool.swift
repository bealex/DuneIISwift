import Foundation

extension Simulation {
    public struct UnitSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var isAllocated: Bool
        public var index: UInt16
        public var type: UInt8
        public var houseID: UInt8
        /// `0xFF` when not linked to another entity (mirrors OpenDUNE).
        public var linkedID: UInt8
        /// `orientation[0].current` in OpenDUNE — the unit's body/turret
        /// heading byte. Read by `Script_General_GetOrientation`.
        public var orientationCurrent: Int8
        /// `orientation[0].target` in OpenDUNE (`src/unit.h`'s `OrientationInfo`).
        /// Set by `Unit_SetOrientation` (via `Script_Unit_SetOrientation`,
        /// `Script_Unit_SetTarget`, `Unit_StartMovement`). `tickRotation`
        /// advances `orientationCurrent` toward this byte every 4..8 ticks
        /// at `orientationSpeed` per step.
        public var orientationTarget: Int8
        /// `orientation[0].speed` in OpenDUNE. Signed rotation velocity in
        /// 1/256ths of a turn per rotation tick; `0` means "not rotating."
        /// `Unit_SetOrientation` seeds this as `turningSpeed * 4` with the
        /// sign chosen by shortest arc.
        public var orientationSpeed: Int8
        /// Current action enum. Written by `Script_Unit_SetAction`, read by
        /// the unit state machine.
        public var actionID: UInt8
        /// Cargo / payload counter (harvester spice, transport linked count,
        /// sandworm remaining feeds). Read by `Script_Unit_GetAmount`.
        public var amount: UInt8
        /// Encoded attack target (`Tools_Index_Encode` output). `0` = none.
        public var targetAttack: UInt16
        /// Encoded movement target. `0` = none.
        public var targetMove: UInt16
        /// Encoded origin (carryall-return / harvester-refinery).
        public var originEncoded: UInt16
        /// Tile32 pixel-coordinate position. x = tileX * 256 + 128 for a
        /// tile-centered unit. See `PackedPosition.tile32Center`.
        public var positionX: UInt16
        public var positionY: UInt16
        /// Current hitpoints; `0` means dead. Max hitpoints come from the
        /// `UnitInfo` table (not yet ported).
        public var hitpoints: UInt16
        /// Bitmask of houses that have seen this unit (bit n = houseID n).
        public var seenByHouses: UInt8
        /// Tile-hop clamp factor (1..15ish). Multiplied by 16 inside the
        /// movement tick to cap per-trigger pixel travel. Port of
        /// OpenDUNE's `u->speed` (`src/unit.c:1940`). Written by
        /// `Units.setSpeed`.
        public var speed: UInt8
        /// Subpixel accumulator increment per movement tick. When
        /// `speedRemainder + speedPerTick` overflows past 0xFF a
        /// tile-step fires in the movement direction. OpenDUNE's
        /// `u->speedPerTick` at `src/unit.c:1941`.
        public var speedPerTick: UInt8
        /// Fractional-pixel carry between movement ticks. Accumulates
        /// until the high byte is non-zero, then triggers a move. Port
        /// of OpenDUNE's `u->speedRemainder` (`src/unit.c:104`).
        public var speedRemainder: UInt8
        /// 0..255 input to `Units.setSpeed`. Stored so the calculator
        /// can recompute speedPerTick when game-speed changes (deferred
        /// — we run at a fixed game-speed). Mirrors OpenDUNE's
        /// `u->movingSpeed`.
        public var movingSpeed: UInt8
        /// Visual sprite-offset nudge (affects idle animation). Written by
        /// `Script_Unit_SetSprite`.
        public var spriteOffset: Int8
        /// Remaining frames the unit should blink for. Written by
        /// `Script_Unit_Blink`.
        public var blinkCounter: UInt8
        /// True when the unit is carrying another unit (transport). Written
        /// by `Script_Unit_Pickup` / `Script_Unit_TransportDeliver`.
        public var inTransport: Bool
        /// Was placed directly by the scenario (as opposed to built later).
        /// Controls the 192/256 speed down-scale in `Script_Unit_SetSpeed`.
        public var byScenario: Bool
        /// 14-byte step buffer filled by `Script_Unit_CalculateRoute`. Each
        /// entry is a 3-bit direction (0..7); `0xFF` terminates. Mirrors
        /// OpenDUNE `u->route[14]`.
        public var route: [UInt8]
        /// Tile32 pos32 this unit is currently headed toward for its
        /// *current* route step. Set when a step is dequeued; cleared on
        /// arrival. Zero when idle. Mirrors OpenDUNE `u->currentDestination`.
        public var currentDestinationX: UInt16
        public var currentDestinationY: UInt16
        /// Runtime fire-cooldown counter (`u->fireDelay`). Ticks down by
        /// one per `Scheduler.tick()`; `Script_Unit_Fire` refuses to fire
        /// until it reaches 0. Narrowed to `u8` on disk (OpenDUNE's
        /// in-memory `u16` is always ≤ 255 in practice).
        public var fireDelay: UInt8
        /// `u->o.flags.s.fireTwiceFlip` — flip-flop for `firesTwice`
        /// weapons. Toggles on each fire; when set, the next shot uses
        /// the 5-tick quick reload rather than the full cooldown.
        public var fireTwiceFlip: Bool
        /// Team membership — OpenDUNE stores it as team-pool-index plus
        /// one, with `0` meaning "no team". Kept in that shape so
        /// round-tripping to save bytes matches; readers should subtract
        /// 1 before indexing `TeamPool`.
        public var team: UInt8
        /// Generic per-unit countdown used by `tickUnknown5`
        /// (`src/unit.c:240..286`) to pace sprite animation: when
        /// `timer == 0` and the animation condition fires, bump
        /// `spriteOffset` + set `timer = ui->animationSpeed / 5` (or
        /// 4 / 1 / 3 depending on type / state). Otherwise decrement.
        /// Also used by a handful of other per-unit timers (bullets'
        /// arrival, etc.) — we use it as a catch-all counter field.
        public var timer: UInt16

        public init(
            isUsed: Bool = false,
            isAllocated: Bool = false,
            index: UInt16 = 0,
            type: UInt8 = 0,
            houseID: UInt8 = 0,
            linkedID: UInt8 = 0,
            orientationCurrent: Int8 = 0,
            orientationTarget: Int8 = 0,
            orientationSpeed: Int8 = 0,
            actionID: UInt8 = 0,
            amount: UInt8 = 0,
            targetAttack: UInt16 = 0,
            targetMove: UInt16 = 0,
            originEncoded: UInt16 = 0,
            positionX: UInt16 = 0,
            positionY: UInt16 = 0,
            hitpoints: UInt16 = 0,
            seenByHouses: UInt8 = 0,
            speed: UInt8 = 0,
            speedPerTick: UInt8 = 0,
            speedRemainder: UInt8 = 0,
            movingSpeed: UInt8 = 0,
            spriteOffset: Int8 = 0,
            blinkCounter: UInt8 = 0,
            inTransport: Bool = false,
            byScenario: Bool = false,
            route: [UInt8] = [UInt8](repeating: 0xFF, count: 14),
            currentDestinationX: UInt16 = 0,
            currentDestinationY: UInt16 = 0,
            fireDelay: UInt8 = 0,
            fireTwiceFlip: Bool = false,
            team: UInt8 = 0,
            timer: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.isAllocated = isAllocated
            self.index = index
            self.type = type
            self.houseID = houseID
            self.linkedID = linkedID
            self.orientationCurrent = orientationCurrent
            self.orientationTarget = orientationTarget
            self.orientationSpeed = orientationSpeed
            self.actionID = actionID
            self.amount = amount
            self.targetAttack = targetAttack
            self.targetMove = targetMove
            self.originEncoded = originEncoded
            self.positionX = positionX
            self.positionY = positionY
            self.hitpoints = hitpoints
            self.seenByHouses = seenByHouses
            self.speed = speed
            self.speedPerTick = speedPerTick
            self.speedRemainder = speedRemainder
            self.movingSpeed = movingSpeed
            self.spriteOffset = spriteOffset
            self.blinkCounter = blinkCounter
            self.inTransport = inTransport
            self.byScenario = byScenario
            self.route = route
            self.currentDestinationX = currentDestinationX
            self.currentDestinationY = currentDestinationY
            self.fireDelay = fireDelay
            self.fireTwiceFlip = fireTwiceFlip
            self.team = team
            self.timer = timer
        }
    }

    public struct UnitPool: Sendable, Equatable {
        public static let capacity = 102
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [UnitSlot]
        /// Slot indices in allocation order. OpenDUNE's `g_unitFindArray`.
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: UnitSlot(), count: Self.capacity)
            self.findArray = []
        }

        public subscript(index: Int) -> UnitSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(at index: Int, type: UInt8, houseID: UInt8) -> Int? {
            guard index >= 0, index < Self.capacity else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = UnitSlot(
                isUsed: true,
                isAllocated: true,
                index: UInt16(index),
                type: type,
                houseID: houseID,
                linkedID: 0xFF
            )
            findArray.append(index)
            return index
        }

        @discardableResult
        public mutating func allocate(in range: ClosedRange<Int>, type: UInt8, houseID: UInt8) -> Int? {
            for index in range where index >= 0 && index < Self.capacity && !slots[index].isUsed {
                return allocate(at: index, type: type, houseID: houseID)
            }
            return nil
        }

        /// Port of `Unit_Allocate` (`src/pool/unit.c:107`) with
        /// `index == UNIT_INDEX_INVALID` — scans the per-type
        /// `UnitInfo.indexStart..indexEnd` for the first unused slot.
        /// Returns `nil` on full range, invalid type, or houseID ≥ 6.
        /// OpenDUNE's `h->unitCount >= h->unitCountMax` gate is deferred
        /// (needs `HouseSlot.unitCount` + `g_table_houseInfo`).
        @discardableResult
        public mutating func allocateForType(type: UInt8, houseID: UInt8) -> Int? {
            guard houseID < 6 else { return nil }
            guard let info = UnitInfo.lookup(type) else { return nil }
            let start = Int(info.indexStart)
            let end = Int(info.indexEnd)
            guard start >= 0, end < Self.capacity, start <= end else { return nil }
            for index in start...end where !slots[index].isUsed {
                return allocate(at: index, type: type, houseID: houseID)
            }
            return nil
        }

        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacity, slots[index].isUsed else { return }
            slots[index].isUsed = false
            slots[index].isAllocated = false
            if let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }

        /// Port of OpenDUNE's `Unit_Recount` (`src/pool/unit.c:75`).
        /// Discards the current `findArray` and rebuilds it in pool
        /// index order (0..<capacity, including every `isUsed` slot).
        /// OpenDUNE calls this after `SaveGame_LoadFile` so the
        /// post-load iteration order is fixed regardless of the
        /// save chunk's on-disk order. Our save-loader allocates in
        /// on-disk order, which for SAVE007 places u39 at position 4
        /// in `findArray`, and drives per-tick unit dispatch order
        /// out of sync with OpenDUNE. Calling `recount()` after a
        /// save load restores pool-index order.
        public mutating func recount() {
            findArray.removeAll(keepingCapacity: true)
            for i in 0..<Self.capacity where slots[i].isUsed {
                findArray.append(i)
            }
        }
    }
}
