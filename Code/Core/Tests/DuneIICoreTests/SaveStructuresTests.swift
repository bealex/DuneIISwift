import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Structures")
struct SaveStructuresTests {
    @Test("structure record is exactly 88 bytes (71 object + 17 tail)")
    func recordSizeIs88() {
        #expect(Formats.Save.Structures.slotSize == 88)
    }

    // MARK: Synthetic round-trip

    @Test("pinned two-structure BLDG body round-trips header and tail fields")
    func pinnedTwoStruct() throws {
        // Slot 0: a Harkonnen construction yard, mid-upgrade, building a barracks.
        let slot0 = makeStructureRecord(
            index: 2,
            type: 7, // some structure-type code
            houseID: 0, // Harkonnen
            positionX: 0x0A00, positionY: 0x0400,
            hitpoints: 800,
            flagsDword: 0x01 | 0x02, // used | allocated; isUnit clear
            creatorHouseID: 0,
            rotationSpriteDiff: 0,
            objectType: 3,        // producing structure-type 3
            upgradeLevel: 1,
            upgradeTimeLeft: 40,
            countDown: 120,
            buildCostRemainder: 7,
            state: -1,            // invalid / idle
            hitpointsMax: 1000
        )
        // Slot 1: a plain wall segment, state 0, zero upgrade.
        let slot1 = makeStructureRecord(
            index: 10,
            type: 20,
            houseID: 1,
            positionX: 0, positionY: 0,
            hitpoints: 50,
            flagsDword: 0x01,
            creatorHouseID: 1,
            rotationSpriteDiff: 0,
            objectType: 0,
            upgradeLevel: 0,
            upgradeTimeLeft: 0,
            countDown: 0,
            buildCostRemainder: 0,
            state: 0,
            hitpointsMax: 50
        )
        let body = slot0 + slot1
        #expect(body.count == 2 * 88)

        let structs = try Formats.Save.Structures.decode(body)
        #expect(structs.slots.count == 2)

        let s0 = structs.slots[0]
        #expect(s0.object.index == 2)
        #expect(s0.object.type == 7)
        #expect(s0.object.houseID == 0)
        #expect(s0.object.positionX == 0x0A00)
        #expect(s0.object.positionY == 0x0400)
        #expect(s0.object.hitpoints == 800)
        #expect(s0.object.flags.used)
        #expect(s0.object.flags.allocated)
        #expect(!s0.object.flags.isUnit) // BLDG always has isUnit clear
        #expect(s0.creatorHouseID == 0)
        #expect(s0.rotationSpriteDiff == 0)
        #expect(s0.objectType == 3)
        #expect(s0.upgradeLevel == 1)
        #expect(s0.upgradeTimeLeft == 40)
        #expect(s0.countDown == 120)
        #expect(s0.buildCostRemainder == 7)
        #expect(s0.state == -1) // signed
        #expect(s0.hitpointsMax == 1000)

        #expect(structs.slots[1].state == 0)
        #expect(structs.slots[1].object.type == 20)
    }

    @Test("state field is signed — 0xFFFF bytes decode to -1, not 65535")
    func stateIsSigned() throws {
        let slot = makeStructureRecord(
            index: 0, type: 0, houseID: 0,
            positionX: 0, positionY: 0, hitpoints: 1,
            flagsDword: 0x01,
            creatorHouseID: 0, rotationSpriteDiff: 0,
            objectType: 0, upgradeLevel: 0, upgradeTimeLeft: 0,
            countDown: 0, buildCostRemainder: 0,
            state: -1, hitpointsMax: 1
        )
        let structs = try Formats.Save.Structures.decode(slot)
        #expect(structs.slots[0].state == -1)
    }

    // MARK: Failure modes

    @Test("misaligned BLDG body rejected")
    func misalignedBody() {
        let body = Data(count: 88 + 40)
        #expect(throws: Formats.Save.Structures.DecodeError.misalignedBody(length: body.count)) {
            _ = try Formats.Save.Structures.decode(body)
        }
    }

    @Test("empty body decodes to zero slots")
    func emptyBody() throws {
        let structs = try Formats.Save.Structures.decode(Data())
        #expect(structs.slots.isEmpty)
    }

    // MARK: Real data

    @Test("_SAVE001.DAT BLDG chunk decodes into plausibly-typed structures")
    func realSave001Bldg() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        guard let chunk = container.chunk(named: "BLDG") else {
            Issue.record("BLDG chunk missing"); return
        }
        #expect(chunk.count % 88 == 0)
        let structs = try Formats.Save.Structures.decode(chunk)

        #expect(structs.slots.count <= 79) // only the [0,78] allocable range appears
        for slot in structs.slots {
            #expect(slot.object.flags.used)
            #expect(!slot.object.flags.isUnit) // structures never set isUnit
            #expect(slot.object.type <= 44)
            #expect(slot.object.houseID <= 5)
            #expect(slot.object.index <= 81)
            #expect(Int(slot.object.hitpoints) <= Int(slot.hitpointsMax) + 1 || slot.hitpointsMax == 0)
        }
    }
}

// MARK: - Helpers

private func makeStructureRecord(
    index: UInt16,
    type: UInt8,
    houseID: UInt8,
    positionX: UInt16, positionY: UInt16,
    hitpoints: UInt16,
    flagsDword: UInt32,
    creatorHouseID: UInt16,
    rotationSpriteDiff: UInt16,
    objectType: UInt16,
    upgradeLevel: UInt8,
    upgradeTimeLeft: UInt8,
    countDown: UInt16,
    buildCostRemainder: UInt16,
    state: Int16,
    hitpointsMax: UInt16
) -> Data {
    var d = Data()
    // Object header (71 bytes)
    d.append(uint16LE: index)      // 0
    d.append(type)                 // 2
    d.append(0xFF)                 // 3 linkedID
    d.append(uint32LE: flagsDword) // 4
    d.append(houseID)              // 8
    d.append(0)                    // 9 seenByHouses
    d.append(uint16LE: positionX)  // 10
    d.append(uint16LE: positionY)  // 12
    d.append(uint16LE: hitpoints)  // 14
    // ScriptState (55 bytes zeroed — valid empty state)
    d.append(Data(count: 55))      // 16..71
    precondition(d.count == 71)
    // Structure tail (17 bytes)
    d.append(uint16LE: creatorHouseID)     // 71
    d.append(uint16LE: rotationSpriteDiff) // 73
    d.append(0)                            // 75 pad
    d.append(uint16LE: objectType)         // 76
    d.append(upgradeLevel)                 // 78
    d.append(upgradeTimeLeft)              // 79
    d.append(uint16LE: countDown)          // 80
    d.append(uint16LE: buildCostRemainder) // 82
    d.append(int16LE: state)               // 84
    d.append(uint16LE: hitpointsMax)       // 86
    precondition(d.count == 88)
    return d
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
    mutating func append(int16LE value: Int16) {
        append(uint16LE: UInt16(bitPattern: value))
    }
}
