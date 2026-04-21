import Foundation

extension Simulation {
    /// Port of OpenDUNE's `ExplosionType` enum (`src/explosion.h:13`).
    /// Raw values match the game data — `peek(1)` from
    /// `Script_Unit_ExplosionSingle` arrives as one of these IDs.
    public enum ExplosionType: UInt16, Sendable, Equatable {
        case impactSmall          = 0
        case impactMedium         = 1
        case impactLarge          = 2
        case impactExplode        = 3
        case saboteurDeath        = 4
        case saboteurInfiltrate   = 5
        case tankExplode          = 6
        case deviatorGas          = 7
        case sandBurst            = 8
        case tankFlames           = 9
        case wheeledVehicle       = 10
        case deathHand            = 11
        case unused12             = 12
        case sandwormSwallow      = 13
        case structure            = 14
        case smokePlume           = 15
        case ornithopterCrash     = 16
        case carryallCrash        = 17
        case miniRocket           = 18
        case spiceBloomTremor     = 19

        /// OpenDUNE `EXPLOSIONTYPE_MAX = 20`. Values `≥ 20` are invalid.
        public static let max: UInt16 = 20
        public static let invalid: UInt16 = 0xFFFF
    }

    public struct ExplosionSlot: Sendable, Equatable {
        public var isActive: Bool
        public var type: UInt16
        public var positionX: UInt16
        public var positionY: UInt16
        public var houseID: UInt8
        /// Coarse frame counter decrementing to 0 (then the slot frees).
        /// Stand-in for the per-explosion command stream, which lives in
        /// presentation. Default `60` ≈ one second at 60 FPS — matches
        /// the rough lifetime of an `IMPACT_MEDIUM` explosion in vanilla.
        public var remainingFrames: UInt16

        public init(
            isActive: Bool = false,
            type: UInt16 = ExplosionType.invalid,
            positionX: UInt16 = 0,
            positionY: UInt16 = 0,
            houseID: UInt8 = 0xFF,
            remainingFrames: UInt16 = 0
        ) {
            self.isActive = isActive
            self.type = type
            self.positionX = positionX
            self.positionY = positionY
            self.houseID = houseID
            self.remainingFrames = remainingFrames
        }
    }

    public struct ExplosionPool: Sendable, Equatable {
        public static let capacity = 32

        public private(set) var slots: [ExplosionSlot]

        public init() {
            self.slots = Array(repeating: ExplosionSlot(), count: Self.capacity)
        }

        public subscript(index: Int) -> ExplosionSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        /// Frees every active slot whose position packs to `packed`.
        /// Mirrors OpenDUNE's `Explosion_StopAtPosition` — when a new
        /// explosion starts on a tile that already has one, the old
        /// one is replaced rather than stacked.
        public mutating func stopAtPosition(packed: UInt16) {
            for i in 0..<slots.count where slots[i].isActive {
                let sPacked = Pathfinder.packedTile(x: slots[i].positionX, y: slots[i].positionY)
                if sPacked == packed {
                    slots[i] = ExplosionSlot()
                }
            }
        }

        /// First-unused-slot allocation. Returns the slot index, or
        /// `nil` when the pool is full. Matches OpenDUNE's behaviour of
        /// silently dropping explosions past capacity.
        @discardableResult
        public mutating func add(
            type: UInt16,
            positionX: UInt16,
            positionY: UInt16,
            houseID: UInt8 = 0xFF,
            frames: UInt16 = 60
        ) -> Int? {
            for i in 0..<slots.count where !slots[i].isActive {
                slots[i] = ExplosionSlot(
                    isActive: true, type: type,
                    positionX: positionX, positionY: positionY,
                    houseID: houseID, remainingFrames: frames
                )
                return i
            }
            return nil
        }

        /// Frees a specific slot. Used by the presentation-layer tick
        /// when `remainingFrames` hits 0 (not yet wired here).
        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacity else { return }
            slots[index] = ExplosionSlot()
        }
    }
}
