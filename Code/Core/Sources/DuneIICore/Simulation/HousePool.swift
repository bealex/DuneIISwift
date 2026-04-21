import Foundation

extension Simulation {
    public struct HouseSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var index: UInt8
        /// `0xFFFF` when no starport-linked unit (mirrors OpenDUNE).
        public var starportLinkedID: UInt16
        /// Spending cash on hand. Drained per tick by BUSY yards
        /// (slice 6b); refunded on cancel. Seeded from
        /// `Scenario.HouseLayout.credits` or the save's `PLYR` record.
        /// Slice 6a.
        public var credits: UInt16
        /// Cap on storable credits — sum of refinery + silo capacities.
        /// Stored so save round-trips survive; live refreshes come
        /// with the HUD / economy slice.
        public var creditsStorage: UInt16
        /// Scenario win-condition target (harvester revenue needed).
        /// Pure read — never written by the engine.
        public var creditsQuota: UInt16

        public init(
            isUsed: Bool = false,
            index: UInt8 = 0,
            starportLinkedID: UInt16 = 0,
            credits: UInt16 = 0,
            creditsStorage: UInt16 = 0,
            creditsQuota: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.index = index
            self.starportLinkedID = starportLinkedID
            self.credits = credits
            self.creditsStorage = creditsStorage
            self.creditsQuota = creditsQuota
        }
    }

    public struct HousePool: Sendable, Equatable {
        public static let capacity = 6
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [HouseSlot]
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: HouseSlot(), count: Self.capacity)
            self.findArray = []
        }

        public subscript(index: Int) -> HouseSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(at index: Int) -> Int? {
            guard index >= 0, index < Self.capacity else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = HouseSlot(
                isUsed: true,
                index: UInt8(index),
                starportLinkedID: 0xFFFF
            )
            findArray.append(index)
            return index
        }

        /// Removes the house from `findArray` but **leaves `slots[i].isUsed == true`**,
        /// mirroring OpenDUNE's `House_Free` quirk. See
        /// `Documentation/Insights/simulation-house-free-leaves-used.md`.
        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacity, slots[index].isUsed else { return }
            if let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }
    }
}
