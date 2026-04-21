import Foundation

extension Formats.Save {
    /// Body of the `BLDG` chunk: a packed array of 88-byte Structure records.
    ///
    /// Wire layout: `Documentation/Formats/SAVE.md` §10. Shares the 71-byte
    /// `ObjectHeader` with `UNIT`; adds a 17-byte structure tail from
    /// `s_saveStructure` (`src/saveload/structure.c`).
    public struct Structures: Sendable, Equatable {
        public let slots: [Slot]

        /// Bytes per serialised structure record.
        public static let slotSize = 88

        public enum DecodeError: Error, Equatable, Sendable {
            case misalignedBody(length: Int)
        }

        public struct Slot: Sendable, Equatable {
            public let object: ObjectHeader
            public let creatorHouseID: UInt16
            public let rotationSpriteDiff: UInt16
            public let objectType: UInt16
            public let upgradeLevel: UInt8
            public let upgradeTimeLeft: UInt8
            public let countDown: UInt16
            public let buildCostRemainder: UInt16
            /// `state` is signed on disk (`SLDT_INT16`). `-1` = invalid/idle.
            public let state: Int16
            public let hitpointsMax: UInt16
        }

        public static func decode(_ body: Data) throws -> Structures {
            if body.count % slotSize != 0 {
                throw DecodeError.misalignedBody(length: body.count)
            }
            let slotCount = body.count / slotSize
            var slots: [Slot] = []
            slots.reserveCapacity(slotCount)
            var cursor = body.startIndex
            for _ in 0..<slotCount {
                slots.append(decodeSlot(body, at: cursor))
                cursor += slotSize
            }
            return Structures(slots: slots)
        }

        private static func decodeSlot(_ data: Data, at base: Int) -> Slot {
            let object = Formats.Save.decodeObjectHeader(data, at: base)
            var c = base + ObjectHeader.size
            let creatorHouseID = readU16LE(data, at: c); c += 2
            let rotationSpriteDiff = readU16LE(data, at: c); c += 2
            c += 1 // SLD_EMPTY(UINT8) pad
            let objectType = readU16LE(data, at: c); c += 2
            let upgradeLevel = data[c]; c += 1
            let upgradeTimeLeft = data[c]; c += 1
            let countDown = readU16LE(data, at: c); c += 2
            let buildCostRemainder = readU16LE(data, at: c); c += 2
            let state = Int16(bitPattern: readU16LE(data, at: c)); c += 2
            let hitpointsMax = readU16LE(data, at: c)
            return Slot(
                object: object,
                creatorHouseID: creatorHouseID,
                rotationSpriteDiff: rotationSpriteDiff,
                objectType: objectType,
                upgradeLevel: upgradeLevel,
                upgradeTimeLeft: upgradeTimeLeft,
                countDown: countDown,
                buildCostRemainder: buildCostRemainder,
                state: state,
                hitpointsMax: hitpointsMax
            )
        }
    }
}
