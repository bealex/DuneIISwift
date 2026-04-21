import Foundation

extension Simulation {
    public struct HouseSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var index: UInt8
        /// `0xFFFF` when no starport-linked unit (mirrors OpenDUNE).
        public var starportLinkedID: UInt16

        public init(
            isUsed: Bool = false,
            index: UInt8 = 0,
            starportLinkedID: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.index = index
            self.starportLinkedID = starportLinkedID
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
