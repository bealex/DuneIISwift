import Foundation

extension Simulation {
    public struct StructureSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var isAllocated: Bool
        public var index: UInt16
        public var type: UInt8
        public var houseID: UInt8
        public var linkedID: UInt8
        /// Signed structure state enum: `-2` DETECT (write-only sentinel),
        /// `-1` JUSTBUILT, `0` IDLE, `1` BUSY, `2` READY.
        public var state: Int16
        /// Production / unload countdown. Read by `Script_Structure_SetState`
        /// during DETECT resolution.
        public var countDown: UInt16
        /// Tile32 pixel-coordinate position of the structure's upper-left
        /// cell's centre. Structures span 1..6 tiles; `positionX/Y` is the
        /// anchor, not the centre of the full footprint.
        public var positionX: UInt16
        public var positionY: UInt16
        /// Current hitpoints; `0` means destroyed.
        public var hitpoints: UInt16
        /// Current 8-step turret rotation `0..7` (N, NE, E, SE, S, SW, W, NW).
        /// Read by `Script_Structure_RotateTurret` / `GetDirection` and
        /// written on each turret-rotate tick. Non-turret structures
        /// leave this at 0.
        public var rotationSpriteDiff: UInt8

        public init(
            isUsed: Bool = false,
            isAllocated: Bool = false,
            index: UInt16 = 0,
            type: UInt8 = 0,
            houseID: UInt8 = 0,
            linkedID: UInt8 = 0,
            state: Int16 = 0,
            countDown: UInt16 = 0,
            positionX: UInt16 = 0,
            positionY: UInt16 = 0,
            hitpoints: UInt16 = 0,
            rotationSpriteDiff: UInt8 = 0
        ) {
            self.isUsed = isUsed
            self.isAllocated = isAllocated
            self.index = index
            self.type = type
            self.houseID = houseID
            self.linkedID = linkedID
            self.state = state
            self.countDown = countDown
            self.positionX = positionX
            self.positionY = positionY
            self.hitpoints = hitpoints
            self.rotationSpriteDiff = rotationSpriteDiff
        }
    }

    public struct StructurePool: Sendable, Equatable {
        public static let capacityHard = 82
        public static let capacitySoft = 79
        public static let indexWall = 79
        public static let indexSlab2x2 = 80
        public static let indexSlab1x1 = 81
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [StructureSlot]
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: StructureSlot(), count: Self.capacityHard)
            self.findArray = []
        }

        public subscript(index: Int) -> StructureSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(at index: Int, type: UInt8, houseID: UInt8) -> Int? {
            guard index >= 0, index < Self.capacitySoft else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = StructureSlot(
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
            for index in range where index >= 0 && index < Self.capacitySoft && !slots[index].isUsed {
                return allocate(at: index, type: type, houseID: houseID)
            }
            return nil
        }

        /// Re-initialises one of the three reserved aggregate slots
        /// (`indexWall`, `indexSlab2x2`, `indexSlab1x1`). Always succeeds;
        /// previous content is discarded. Does NOT touch `findArray`.
        @discardableResult
        public mutating func allocateReserved(at index: Int, type: UInt8) -> Int {
            precondition(
                index == Self.indexWall || index == Self.indexSlab2x2 || index == Self.indexSlab1x1,
                "allocateReserved called with non-reserved index \(index)"
            )
            slots[index] = StructureSlot(
                isUsed: true,
                isAllocated: true,
                index: UInt16(index),
                type: type,
                houseID: 0,
                linkedID: 0xFF
            )
            return index
        }

        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacityHard, slots[index].isUsed else { return }
            slots[index].isUsed = false
            slots[index].isAllocated = false
            // Reserved slots never appear in the findArray; only normal slots
            // need to be removed from it.
            if index < Self.capacitySoft, let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }
    }
}
