import Foundation

extension Formats.Save {
    /// Body of the `PLYR` chunk: a packed array of allocated `House` records.
    ///
    /// Wire layout documented in `Documentation/Formats/SAVE.md` §8.
    /// Reference: OpenDUNE `src/saveload/house.c` (`s_saveHouse` and
    /// `House_Load`).
    public struct Player: Sendable, Equatable {
        public let slots: [HouseSlot]

        /// Bytes per serialised house record. Chunk body size must be a
        /// multiple of this.
        public static let slotSize = 66

        public enum DecodeError: Error, Equatable, Sendable {
            case misalignedBody(length: Int)
        }

        public struct HouseSlot: Sendable, Equatable {
            public let index: UInt16
            public let harvestersIncoming: UInt16
            public let flags: HouseFlags
            public let unitCount: UInt16
            public let unitCountMax: UInt16
            public let unitCountEnemy: UInt16
            public let unitCountAllied: UInt16
            public let structuresBuilt: UInt32
            public let credits: UInt16
            public let creditsStorage: UInt16
            public let powerProduction: UInt16
            public let powerUsage: UInt16
            public let windtrapCount: UInt16
            public let creditsQuota: UInt16
            public let palacePositionX: UInt16
            public let palacePositionY: UInt16
            public let timerUnitAttack: UInt16
            public let timerSandwormAttack: UInt16
            public let timerStructureAttack: UInt16
            public let starportTimeLeft: UInt16
            public let starportLinkedID: UInt16
            /// Five `(unitType, tilePosition)` pairs, serialised as 10 u16s.
            /// Surface raw for now; a typed projection can land when the AI
            /// rebuild queue grows a consumer.
            public let aiStructureRebuild: [UInt16]
        }

        public struct HouseFlags: Sendable, Equatable {
            public let rawWord: UInt16

            public var used: Bool               { rawWord & 0x01 != 0 }
            public var human: Bool              { rawWord & 0x02 != 0 }
            public var doneFullScaleAttack: Bool { rawWord & 0x04 != 0 }
            public var isAIActive: Bool         { rawWord & 0x08 != 0 }
            public var radarActivated: Bool     { rawWord & 0x10 != 0 }
        }

        /// First slot flagged `human`, if any. Vanilla saves always have
        /// exactly one; defensive code should still treat nil as possible.
        public var humanSlot: HouseSlot? {
            slots.first(where: { $0.flags.human })
        }

        public static func decode(_ body: Data) throws -> Player {
            if body.count % slotSize != 0 {
                throw DecodeError.misalignedBody(length: body.count)
            }
            let slotCount = body.count / slotSize
            var slots: [HouseSlot] = []
            slots.reserveCapacity(slotCount)
            var cursor = body.startIndex
            for _ in 0..<slotCount {
                slots.append(decodeSlot(body, at: cursor))
                cursor += slotSize
            }
            return Player(slots: slots)
        }

        private static func decodeSlot(_ data: Data, at base: Int) -> HouseSlot {
            var c = base
            let index = readU16LE(data, at: c); c += 2
            let harvestersIncoming = readU16LE(data, at: c); c += 2
            let flagsWord = readU16LE(data, at: c); c += 2
            let unitCount = readU16LE(data, at: c); c += 2
            let unitCountMax = readU16LE(data, at: c); c += 2
            let unitCountEnemy = readU16LE(data, at: c); c += 2
            let unitCountAllied = readU16LE(data, at: c); c += 2
            let structuresBuilt = readU32LE(data, at: c); c += 4
            let credits = readU16LE(data, at: c); c += 2
            let creditsStorage = readU16LE(data, at: c); c += 2
            let powerProduction = readU16LE(data, at: c); c += 2
            let powerUsage = readU16LE(data, at: c); c += 2
            let windtrapCount = readU16LE(data, at: c); c += 2
            let creditsQuota = readU16LE(data, at: c); c += 2
            let palaceX = readU16LE(data, at: c); c += 2
            let palaceY = readU16LE(data, at: c); c += 2
            c += 2 // SLD_EMPTY(UINT16) pad
            let timerUnitAttack = readU16LE(data, at: c); c += 2
            let timerSandwormAttack = readU16LE(data, at: c); c += 2
            let timerStructureAttack = readU16LE(data, at: c); c += 2
            let starportTimeLeft = readU16LE(data, at: c); c += 2
            let starportLinkedID = readU16LE(data, at: c); c += 2
            var aiRebuild: [UInt16] = []
            aiRebuild.reserveCapacity(10)
            for _ in 0..<10 {
                aiRebuild.append(readU16LE(data, at: c)); c += 2
            }
            return HouseSlot(
                index: index,
                harvestersIncoming: harvestersIncoming,
                flags: HouseFlags(rawWord: flagsWord),
                unitCount: unitCount,
                unitCountMax: unitCountMax,
                unitCountEnemy: unitCountEnemy,
                unitCountAllied: unitCountAllied,
                structuresBuilt: structuresBuilt,
                credits: credits,
                creditsStorage: creditsStorage,
                powerProduction: powerProduction,
                powerUsage: powerUsage,
                windtrapCount: windtrapCount,
                creditsQuota: creditsQuota,
                palacePositionX: palaceX,
                palacePositionY: palaceY,
                timerUnitAttack: timerUnitAttack,
                timerSandwormAttack: timerSandwormAttack,
                timerStructureAttack: timerStructureAttack,
                starportTimeLeft: starportTimeLeft,
                starportLinkedID: starportLinkedID,
                aiStructureRebuild: aiRebuild
            )
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
    }
}
