import Foundation

extension Formats.Save {
    /// 71-byte `Object` header shared by the `UNIT` and `BLDG` chunks.
    ///
    /// Wire layout: `Documentation/Formats/SAVE.md` §9.2 + §9.1 (nested script).
    /// Reference: OpenDUNE `src/saveload/object.c` + `scriptengine.c`.
    public struct ObjectHeader: Sendable, Equatable {
        public let index: UInt16
        public let type: UInt8
        public let linkedID: UInt8
        public let flags: ObjectFlags
        public let houseID: UInt8
        public let seenByHouses: UInt8
        public let positionX: UInt16
        public let positionY: UInt16
        public let hitpoints: UInt16
        public let script: ScriptState

        public static let size = 71
    }

    /// 55-byte nested `ScriptEngine` state.
    public struct ScriptState: Sendable, Equatable {
        public let delay: UInt16
        /// Word offset of the next instruction within the entry-point's code.
        /// On disk this is a callback-encoded `u32`; at rest it's a plain word index.
        public let scriptOffset: UInt32
        public let returnValue: UInt16
        public let framePointer: UInt8
        public let stackPointer: UInt8
        public let variables: [UInt16]  // 5 entries
        public let stack: [UInt16]      // 15 entries
        public let isSubroutine: UInt8

        public static let size = 55
    }

    /// Packed 32-bit object-flags word. Bit layout mirrors OpenDUNE
    /// `saveload/saveload.c:160–182`. Only 18 bits are meaningful; round-trip
    /// is preserved via `rawDword`.
    public struct ObjectFlags: Sendable, Equatable {
        public let rawDword: UInt32

        public var used: Bool          { rawDword & 0x000001 != 0 }
        public var allocated: Bool     { rawDword & 0x000002 != 0 }
        public var isNotOnMap: Bool    { rawDword & 0x000004 != 0 }
        public var isSmoking: Bool     { rawDword & 0x000008 != 0 }
        public var fireTwiceFlip: Bool { rawDword & 0x000010 != 0 }
        public var animationFlip: Bool { rawDword & 0x000020 != 0 }
        public var bulletIsBig: Bool   { rawDword & 0x000040 != 0 }
        public var isWobbling: Bool    { rawDword & 0x000080 != 0 }
        public var inTransport: Bool   { rawDword & 0x000100 != 0 }
        public var byScenario: Bool    { rawDword & 0x000200 != 0 }
        public var degrades: Bool      { rawDword & 0x000400 != 0 }
        public var isHighlighted: Bool { rawDword & 0x000800 != 0 }
        public var isDirty: Bool       { rawDword & 0x001000 != 0 }
        public var repairing: Bool     { rawDword & 0x002000 != 0 }
        public var onHold: Bool        { rawDword & 0x004000 != 0 }
        public var isUnit: Bool        { rawDword & 0x010000 != 0 }
        public var upgrading: Bool     { rawDword & 0x020000 != 0 }
    }

    // MARK: - Decoding

    static func decodeObjectHeader(_ data: Data, at base: Int) -> ObjectHeader {
        var c = base
        let index = readU16LE(data, at: c); c += 2
        let type = data[c]; c += 1
        let linkedID = data[c]; c += 1
        let flagsDword = readU32LE(data, at: c); c += 4
        let houseID = data[c]; c += 1
        let seenByHouses = data[c]; c += 1
        let positionX = readU16LE(data, at: c); c += 2
        let positionY = readU16LE(data, at: c); c += 2
        let hitpoints = readU16LE(data, at: c); c += 2
        let script = decodeScriptState(data, at: c)
        return ObjectHeader(
            index: index,
            type: type,
            linkedID: linkedID,
            flags: ObjectFlags(rawDword: flagsDword),
            houseID: houseID,
            seenByHouses: seenByHouses,
            positionX: positionX,
            positionY: positionY,
            hitpoints: hitpoints,
            script: script
        )
    }

    static func decodeScriptState(_ data: Data, at base: Int) -> ScriptState {
        var c = base
        let delay = readU16LE(data, at: c); c += 2
        let scriptOffset = readU32LE(data, at: c); c += 4
        c += 4 // SLD_EMPTY(UINT32) pad
        let returnValue = readU16LE(data, at: c); c += 2
        let framePointer = data[c]; c += 1
        let stackPointer = data[c]; c += 1
        var variables: [UInt16] = []; variables.reserveCapacity(5)
        for _ in 0..<5 { variables.append(readU16LE(data, at: c)); c += 2 }
        var stack: [UInt16] = []; stack.reserveCapacity(15)
        for _ in 0..<15 { stack.append(readU16LE(data, at: c)); c += 2 }
        let isSubroutine = data[c]
        return ScriptState(
            delay: delay,
            scriptOffset: scriptOffset,
            returnValue: returnValue,
            framePointer: framePointer,
            stackPointer: stackPointer,
            variables: variables,
            stack: stack,
            isSubroutine: isSubroutine
        )
    }

    static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
