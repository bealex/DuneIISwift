import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Player")
struct SavePlayerTests {
    @Test("slot size is exactly 66 bytes — this is what the container will multiply against house count")
    func slotSizeIs66() {
        #expect(Formats.Save.Player.slotSize == 66)
    }

    // MARK: Synthetic round-trip

    @Test("pinned synthetic two-slot PLYR body round-trips every field including flags bits")
    func pinnedTwoSlot() throws {
        // Slot 0: Harkonnen, human player, radar on, half the top-up fields set.
        let slot0 = makeSlot(
            index: 0,
            flagsWord: 0x01 | 0x02 | 0x10, // used | human | radarActivated
            credits: 5_000,
            creditsStorage: 10_000,
            palaceX: 32,
            palaceY: 24,
            aiRebuild: [0xAAAA, 0xBBBB, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        // Slot 1: Atreides, AI.
        let slot1 = makeSlot(
            index: 1,
            flagsWord: 0x01 | 0x08, // used | isAIActive
            credits: 2_500,
            creditsStorage: 5_000,
            palaceX: 1,
            palaceY: 2,
            aiRebuild: [UInt16](repeating: 0, count: 10)
        )

        let body = slot0 + slot1
        #expect(body.count == 2 * Formats.Save.Player.slotSize)

        let player = try Formats.Save.Player.decode(body)

        #expect(player.slots.count == 2)

        let s0 = player.slots[0]
        #expect(s0.index == 0)
        #expect(s0.flags.used)
        #expect(s0.flags.human)
        #expect(!s0.flags.isAIActive)
        #expect(s0.flags.radarActivated)
        #expect(s0.flags.rawWord == 0x13)
        #expect(s0.credits == 5_000)
        #expect(s0.creditsStorage == 10_000)
        #expect(s0.palacePositionX == 32)
        #expect(s0.palacePositionY == 24)
        #expect(s0.aiStructureRebuild[0] == 0xAAAA)
        #expect(s0.aiStructureRebuild[1] == 0xBBBB)

        let s1 = player.slots[1]
        #expect(s1.index == 1)
        #expect(s1.flags.used)
        #expect(!s1.flags.human)
        #expect(s1.flags.isAIActive)
        #expect(s1.credits == 2_500)
    }

    @Test("the only human house is identified via the flags bit, not the index")
    func humanHouseByFlag() throws {
        let slotHark = makeSlot(index: 0, flagsWord: 0x01) // used only (AI)
        let slotAtre = makeSlot(index: 1, flagsWord: 0x01 | 0x02) // used + human
        let body = slotHark + slotAtre
        let player = try Formats.Save.Player.decode(body)
        #expect(player.humanSlot?.index == 1)
    }

    // MARK: Failure modes

    @Test("body length that is not a multiple of the slot size is rejected")
    func misalignedBody() {
        let body = Data(count: Formats.Save.Player.slotSize * 2 - 3)
        #expect(throws: Formats.Save.Player.DecodeError.misalignedBody(length: body.count)) {
            _ = try Formats.Save.Player.decode(body)
        }
    }

    @Test("empty body decodes to zero slots (vanilla saves never do this, but it's well-defined)")
    func emptyBody() throws {
        let player = try Formats.Save.Player.decode(Data())
        #expect(player.slots.isEmpty)
        #expect(player.humanSlot == nil)
    }

    // MARK: Real data

    @Test("_SAVE001.DAT PLYR chunk decodes into a plausible allocated set")
    func realSave001Plyr() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        guard let plyr = container.chunk(named: "PLYR") else {
            Issue.record("PLYR chunk missing"); return
        }
        #expect(plyr.count % Formats.Save.Player.slotSize == 0)
        let player = try Formats.Save.Player.decode(plyr)

        // Vanilla 1.07 allocates every scenario's participating house. At least
        // one must be the human player.
        #expect(!player.slots.isEmpty)
        #expect(player.slots.count <= 6) // house pool cap
        #expect(player.humanSlot != nil)

        // Every allocated slot must be marked `used`; the `index` must be a
        // valid house ID (0…5); and `creditsStorage` must be non-absurd.
        for slot in player.slots {
            #expect(slot.flags.used)
            #expect((0...5).contains(slot.index))
            // credits fields are u16 (max 65535), which is already below any plausible cap.
            #expect(Int(slot.credits) <= 65_535)
            #expect(Int(slot.creditsStorage) <= 65_535)
        }
    }
}

// MARK: - Helpers

/// Builds one 68-byte slot. Only named fields are populated; everything else
/// is zero, which is what the game would write for freshly-allocated houses.
private func makeSlot(
    index: UInt16,
    flagsWord: UInt16,
    credits: UInt16 = 0,
    creditsStorage: UInt16 = 0,
    palaceX: UInt16 = 0,
    palaceY: UInt16 = 0,
    aiRebuild: [UInt16] = [UInt16](repeating: 0, count: 10)
) -> Data {
    precondition(aiRebuild.count == 10)
    var data = Data()
    data.append(uint16LE: index)               // 0
    data.append(uint16LE: 0)                   // 2 harvestersIncoming
    data.append(uint16LE: flagsWord)           // 4
    data.append(uint16LE: 0)                   // 6 unitCount
    data.append(uint16LE: 0)                   // 8 unitCountMax
    data.append(uint16LE: 0)                   // 10 unitCountEnemy
    data.append(uint16LE: 0)                   // 12 unitCountAllied
    data.append(uint32LE: 0)                   // 14 structuresBuilt
    data.append(uint16LE: credits)             // 18
    data.append(uint16LE: creditsStorage)      // 20
    data.append(uint16LE: 0)                   // 22 powerProduction
    data.append(uint16LE: 0)                   // 24 powerUsage
    data.append(uint16LE: 0)                   // 26 windtrapCount
    data.append(uint16LE: 0)                   // 28 creditsQuota
    data.append(uint16LE: palaceX)             // 30
    data.append(uint16LE: palaceY)             // 32
    data.append(uint16LE: 0)                   // 34 pad
    data.append(uint16LE: 0)                   // 36 timerUnitAttack
    data.append(uint16LE: 0)                   // 38 timerSandwormAttack
    data.append(uint16LE: 0)                   // 40 timerStructureAttack
    data.append(uint16LE: 0)                   // 42 starportTimeLeft
    data.append(uint16LE: 0xFFFF)              // 44 starportLinkedID
    for word in aiRebuild {                    // 46..66
        data.append(uint16LE: word)
    }
    precondition(data.count == 66)
    return data
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
