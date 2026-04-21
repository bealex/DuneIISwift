import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Units")
struct SaveUnitsTests {
    @Test("unit record is exactly 128 bytes (71 object + 57 tail)")
    func recordSizeIs128() {
        #expect(Formats.Save.Units.slotSize == 128)
    }

    // MARK: Synthetic round-trip

    @Test("pinned two-unit UNIT body round-trips header, flags, script block, and tail")
    func pinnedTwoUnit() throws {
        // Unit 0: player trike (type 0), Atreides, used + allocated + isUnit,
        // mid-map, moving to a destination, with a partially-populated script.
        let slot0 = makeUnitRecord(
            index: 0,
            type: 0,
            linkedID: 0xFF,
            flagsDword: 0x0001 | 0x0002 | 0x010000, // used | allocated | isUnit
            houseID: 1, // Atreides
            seenByHouses: 0x02,
            positionX: 0x2000, positionY: 0x1000,
            hitpoints: 100,
            scriptDelay: 3,
            scriptOffset: 7,
            scriptReturnValue: 0x1234,
            currentDestX: 0x3000, currentDestY: 0x1800,
            originEncoded: 0x1234,
            actionID: 5,
            nextActionID: 6,
            fireDelay: 15,
            distanceToDestination: 42,
            targetAttack: 0xFFFF,
            targetMove: 0xABCD,
            amount: 99,
            deviated: 0,
            orientationTurrent: (speed: 2, target: 8, current: 4),
            orientationBody: (speed: -1, target: 12, current: 10),
            speed: 7,
            team: 0,
            timer: 0x4242,
            route: [UInt8](repeating: 0xFF, count: 14)
        )
        // Unit 1: minimum allocation — empty slot at index 5.
        let slot1 = makeUnitRecord(
            index: 5,
            type: 17,
            linkedID: 0xFF,
            flagsDword: 0x01 | 0x10000, // used | isUnit
            houseID: 0,
            seenByHouses: 0,
            positionX: 0, positionY: 0,
            hitpoints: 1,
            scriptDelay: 0,
            scriptOffset: 0,
            scriptReturnValue: 0,
            currentDestX: 0, currentDestY: 0,
            originEncoded: 0,
            actionID: 0,
            nextActionID: 0,
            fireDelay: 0,
            distanceToDestination: 0,
            targetAttack: 0,
            targetMove: 0,
            amount: 0,
            deviated: 0,
            orientationTurrent: (speed: 0, target: 0, current: 0),
            orientationBody: (speed: 0, target: 0, current: 0),
            speed: 0,
            team: 0,
            timer: 0,
            route: [UInt8](repeating: 0, count: 14)
        )
        let body = slot0 + slot1
        #expect(body.count == 2 * 128)

        let units = try Formats.Save.Units.decode(body)
        #expect(units.slots.count == 2)

        let u0 = units.slots[0]
        #expect(u0.object.index == 0)
        #expect(u0.object.type == 0)
        #expect(u0.object.linkedID == 0xFF)
        #expect(u0.object.houseID == 1)
        #expect(u0.object.seenByHouses == 0x02)
        #expect(u0.object.positionX == 0x2000)
        #expect(u0.object.positionY == 0x1000)
        #expect(u0.object.hitpoints == 100)
        #expect(u0.object.flags.used)
        #expect(u0.object.flags.allocated)
        #expect(u0.object.flags.isUnit)
        #expect(!u0.object.flags.isNotOnMap)
        #expect(u0.object.flags.rawDword == 0x010003)

        #expect(u0.object.script.delay == 3)
        #expect(u0.object.script.scriptOffset == 7)
        #expect(u0.object.script.returnValue == 0x1234)
        #expect(u0.object.script.variables.count == 5)
        #expect(u0.object.script.stack.count == 15)

        #expect(u0.currentDestinationX == 0x3000)
        #expect(u0.currentDestinationY == 0x1800)
        #expect(u0.originEncoded == 0x1234)
        #expect(u0.actionID == 5)
        #expect(u0.nextActionID == 6)
        #expect(u0.fireDelay == 15)
        #expect(u0.distanceToDestination == 42)
        #expect(u0.targetAttack == 0xFFFF)
        #expect(u0.targetMove == 0xABCD)
        #expect(u0.amount == 99)
        #expect(u0.deviated == 0)
        #expect(u0.orientation[0].speed == 2)
        #expect(u0.orientation[0].target == 8)
        #expect(u0.orientation[0].current == 4)
        #expect(u0.orientation[1].speed == -1) // signed i8
        #expect(u0.speed == 7)
        #expect(u0.timer == 0x4242)
        #expect(u0.route == [UInt8](repeating: 0xFF, count: 14))

        #expect(units.slots[1].object.index == 5)
        #expect(units.slots[1].object.type == 17)
    }

    // MARK: Failure modes

    @Test("misaligned UNIT body rejected")
    func misalignedBody() {
        let body = Data(count: 128 + 64)
        #expect(throws: Formats.Save.Units.DecodeError.misalignedBody(length: body.count)) {
            _ = try Formats.Save.Units.decode(body)
        }
    }

    @Test("empty body decodes to zero slots")
    func emptyBody() throws {
        let units = try Formats.Save.Units.decode(Data())
        #expect(units.slots.isEmpty)
    }

    // MARK: Real data

    @Test("_SAVE001.DAT UNIT chunk decodes into plausibly-typed units")
    func realSave001Units() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        guard let unitChunk = container.chunk(named: "UNIT") else {
            Issue.record("UNIT chunk missing"); return
        }
        #expect(unitChunk.count % 128 == 0)
        let units = try Formats.Save.Units.decode(unitChunk)

        // Mission 1 has a small, non-empty unit roster.
        #expect(!units.slots.isEmpty)
        #expect(units.slots.count <= 102) // unit pool cap

        for slot in units.slots {
            // All allocated units must have `used` and `isUnit` set.
            #expect(slot.object.flags.used)
            #expect(slot.object.flags.isUnit)
            // unit type must be in [0, 27].
            #expect(slot.object.type <= 27)
            // house must be in [0, 5].
            #expect(slot.object.houseID <= 5)
            // pool index must be in [0, 101].
            #expect(slot.object.index <= 101)
            // hitpoints must be positive for live units, ≤ a large cap.
            #expect(slot.object.hitpoints <= 2000)
        }
    }

    @Test("_SAVE001.DAT does NOT carry an ODUN chunk (vanilla 1.07 quirk)")
    func save001HasNoOdun() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        #expect(container.chunk(named: "ODUN") == nil)
    }
}

// MARK: - Helpers

private func makeUnitRecord(
    index: UInt16,
    type: UInt8,
    linkedID: UInt8,
    flagsDword: UInt32,
    houseID: UInt8,
    seenByHouses: UInt8,
    positionX: UInt16, positionY: UInt16,
    hitpoints: UInt16,
    scriptDelay: UInt16,
    scriptOffset: UInt32,
    scriptReturnValue: UInt16,
    currentDestX: UInt16, currentDestY: UInt16,
    originEncoded: UInt16,
    actionID: UInt8,
    nextActionID: UInt8,
    fireDelay: UInt8,
    distanceToDestination: UInt16,
    targetAttack: UInt16,
    targetMove: UInt16,
    amount: UInt8,
    deviated: UInt8,
    orientationTurrent: (speed: Int8, target: Int8, current: Int8),
    orientationBody: (speed: Int8, target: Int8, current: Int8),
    speed: UInt8,
    team: UInt8,
    timer: UInt16,
    route: [UInt8]
) -> Data {
    precondition(route.count == 14)
    var d = Data()
    // Object header (71 bytes)
    d.append(uint16LE: index)         // 0
    d.append(type)                    // 2
    d.append(linkedID)                // 3
    d.append(uint32LE: flagsDword)    // 4
    d.append(houseID)                 // 8
    d.append(seenByHouses)            // 9
    d.append(uint16LE: positionX)     // 10
    d.append(uint16LE: positionY)     // 12
    d.append(uint16LE: hitpoints)     // 14
    // ScriptEngine block (55 bytes, starts at 16, ends at 71)
    d.append(uint16LE: scriptDelay)          // 16
    d.append(uint32LE: scriptOffset)         // 18
    d.append(uint32LE: 0)                    // 22 empty pad
    d.append(uint16LE: scriptReturnValue)    // 26
    d.append(0)                              // 28 framePointer
    d.append(0)                              // 29 stackPointer
    for _ in 0..<5 { d.append(uint16LE: 0) } // 30..40 variables[5]
    for _ in 0..<15 { d.append(uint16LE: 0) }// 40..70 stack[15]
    d.append(0)                              // 70 isSubroutine
    precondition(d.count == 71)
    // Unit tail (57 bytes)
    d.append(uint16LE: 0)                      // 71 pad
    d.append(uint16LE: currentDestX)           // 73
    d.append(uint16LE: currentDestY)           // 75
    d.append(uint16LE: originEncoded)          // 77
    d.append(actionID)                         // 79
    d.append(nextActionID)                     // 80
    d.append(fireDelay)                        // 81
    d.append(uint16LE: distanceToDestination)  // 82
    d.append(uint16LE: targetAttack)           // 84
    d.append(uint16LE: targetMove)             // 86
    d.append(amount)                           // 88
    d.append(deviated)                         // 89
    d.append(uint16LE: 0)                      // 90 targetLast.x
    d.append(uint16LE: 0)                      // 92 targetLast.y
    d.append(uint16LE: 0)                      // 94 targetPreLast.x
    d.append(uint16LE: 0)                      // 96 targetPreLast.y
    // orientation[0] (turret or body, per OpenDUNE — just "slot 0")
    d.append(UInt8(bitPattern: orientationTurrent.speed))
    d.append(UInt8(bitPattern: orientationTurrent.target))
    d.append(UInt8(bitPattern: orientationTurrent.current))
    // orientation[1]
    d.append(UInt8(bitPattern: orientationBody.speed))
    d.append(UInt8(bitPattern: orientationBody.target))
    d.append(UInt8(bitPattern: orientationBody.current))
    // tail u8 fields
    d.append(0)              // 104 speedPerTick
    d.append(0)              // 105 speedRemainder
    d.append(speed)          // 106 speed
    d.append(0)              // 107 movingSpeed
    d.append(0)              // 108 wobbleIndex
    d.append(0)              // 109 spriteOffset
    d.append(0)              // 110 blinkCounter
    d.append(team)           // 111 team
    d.append(uint16LE: timer)// 112
    d.append(contentsOf: route) // 114..128
    precondition(d.count == 128)
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
}
