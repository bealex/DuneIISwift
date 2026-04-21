import Foundation

extension Formats.Save {
    /// Body of the `UNIT` chunk: a packed array of 128-byte unit records.
    ///
    /// Wire layout: `Documentation/Formats/SAVE.md` §9. Each record is a 71-byte
    /// `ObjectHeader` followed by a 57-byte unit-specific tail
    /// (`s_saveUnit` in `src/saveload/unit.c`).
    public struct Units: Sendable, Equatable {
        public let slots: [Slot]

        /// Bytes per serialised unit record.
        public static let slotSize = 128

        public enum DecodeError: Error, Equatable, Sendable {
            case misalignedBody(length: Int)
        }

        public struct Slot: Sendable, Equatable {
            public let object: ObjectHeader
            public let currentDestinationX: UInt16
            public let currentDestinationY: UInt16
            public let originEncoded: UInt16
            public let actionID: UInt8
            public let nextActionID: UInt8
            /// `u8` on disk — narrowed from the in-memory `u16` `fireDelay`.
            /// The full-width value is carried by the `ODUN` chunk; vanilla
            /// 1.07 saves only have the 8-bit slice.
            public let fireDelay: UInt8
            public let distanceToDestination: UInt16
            public let targetAttack: UInt16
            public let targetMove: UInt16
            public let amount: UInt8
            /// Non-zero when the unit has been deviated (flipped by an Ordos
            /// deviator). In vanilla saves this implies the deviating house
            /// was Ordos; `ODUN` disambiguates in OpenDUNE-written saves.
            public let deviated: UInt8
            public let targetLastX: UInt16
            public let targetLastY: UInt16
            public let targetPreLastX: UInt16
            public let targetPreLastY: UInt16
            /// Two 3-byte `dir24` orientation tracks `(speed, target, current)`.
            public let orientation: [Orientation]
            public let speedPerTick: UInt8
            public let speedRemainder: UInt8
            public let speed: UInt8
            public let movingSpeed: UInt8
            public let wobbleIndex: UInt8
            public let spriteOffset: Int8
            public let blinkCounter: UInt8
            public let team: UInt8
            public let timer: UInt16
            public let route: [UInt8] // 14 entries
        }

        public struct Orientation: Sendable, Equatable {
            public let speed: Int8
            public let target: Int8
            public let current: Int8
        }

        public static func decode(_ body: Data) throws -> Units {
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
            return Units(slots: slots)
        }

        private static func decodeSlot(_ data: Data, at base: Int) -> Slot {
            let object = Formats.Save.decodeObjectHeader(data, at: base)
            var c = base + ObjectHeader.size
            c += 2 // SLD_EMPTY(UINT16) pad
            let curDestX = readU16LE(data, at: c); c += 2
            let curDestY = readU16LE(data, at: c); c += 2
            let originEncoded = readU16LE(data, at: c); c += 2
            let actionID = data[c]; c += 1
            let nextActionID = data[c]; c += 1
            let fireDelay = data[c]; c += 1
            let distanceToDestination = readU16LE(data, at: c); c += 2
            let targetAttack = readU16LE(data, at: c); c += 2
            let targetMove = readU16LE(data, at: c); c += 2
            let amount = data[c]; c += 1
            let deviated = data[c]; c += 1
            let targetLastX = readU16LE(data, at: c); c += 2
            let targetLastY = readU16LE(data, at: c); c += 2
            let targetPreLastX = readU16LE(data, at: c); c += 2
            let targetPreLastY = readU16LE(data, at: c); c += 2
            var orientation: [Orientation] = []
            for _ in 0..<2 {
                let s = Int8(bitPattern: data[c]); c += 1
                let t = Int8(bitPattern: data[c]); c += 1
                let cur = Int8(bitPattern: data[c]); c += 1
                orientation.append(Orientation(speed: s, target: t, current: cur))
            }
            let speedPerTick = data[c]; c += 1
            let speedRemainder = data[c]; c += 1
            let speed = data[c]; c += 1
            let movingSpeed = data[c]; c += 1
            let wobbleIndex = data[c]; c += 1
            let spriteOffset = Int8(bitPattern: data[c]); c += 1
            let blinkCounter = data[c]; c += 1
            let team = data[c]; c += 1
            let timer = readU16LE(data, at: c); c += 2
            var route: [UInt8] = []; route.reserveCapacity(14)
            for i in 0..<14 { route.append(data[c + i]) }
            return Slot(
                object: object,
                currentDestinationX: curDestX,
                currentDestinationY: curDestY,
                originEncoded: originEncoded,
                actionID: actionID,
                nextActionID: nextActionID,
                fireDelay: fireDelay,
                distanceToDestination: distanceToDestination,
                targetAttack: targetAttack,
                targetMove: targetMove,
                amount: amount,
                deviated: deviated,
                targetLastX: targetLastX,
                targetLastY: targetLastY,
                targetPreLastX: targetPreLastX,
                targetPreLastY: targetPreLastY,
                orientation: orientation,
                speedPerTick: speedPerTick,
                speedRemainder: speedRemainder,
                speed: speed,
                movingSpeed: movingSpeed,
                wobbleIndex: wobbleIndex,
                spriteOffset: spriteOffset,
                blinkCounter: blinkCounter,
                team: team,
                timer: timer,
                route: route
            )
        }
    }
}
