import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Info")
struct SaveInfoTests {
    // MARK: Synthetic round-trip

    @Test("pinned synthetic INFO body decodes every field to the expected value")
    func pinnedSyntheticInfo() throws {
        var body = Data()
        body.append(uint16LE: 0x0290) // version

        // 7.1 nested Scenario block (228 bytes)
        body.append(uint16LE: 1_234) // score
        body.append(uint16LE: 0x0001) // winFlags
        body.append(uint16LE: 0x0002) // loseFlags
        body.append(uint32LE: 0x1234_5678) // mapSeed
        body.append(uint16LE: 3) // mapScale
        body.append(uint16LE: 65_000) // timeOut
        appendCString(&body, "BRIEFPIC", totalLen: 14)
        appendCString(&body, "WINPIC", totalLen: 14)
        appendCString(&body, "LOSEPIC", totalLen: 14)
        body.append(uint16LE: 10) // killedAllied
        body.append(uint16LE: 20) // killedEnemy
        body.append(uint16LE: 30) // destroyedAllied
        body.append(uint16LE: 40) // destroyedEnemy
        body.append(uint16LE: 500) // harvestedAllied
        body.append(uint16LE: 600) // harvestedEnemy
        for i in 0..<16 {
            // Slot 0 carries distinct values; slots 1+ are empty (unitID = 0xFFFF).
            if i == 0 {
                body.append(uint16LE: 7)      // unitID
                body.append(uint16LE: 3)      // locationID
                body.append(uint16LE: 1000)   // timeLeft
                body.append(uint16LE: 250)    // timeBetween
                body.append(uint16LE: 1)      // repeat
            } else {
                body.append(uint16LE: 0xFFFF)
                body.append(uint16LE: 0)
                body.append(uint16LE: 0)
                body.append(uint16LE: 0)
                body.append(uint16LE: 0)
            }
        }

        // 7.2 top-level fields (100 bytes)
        body.append(uint16LE: 999) // playerCreditsNoSilo (first)
        body.append(uint16LE: 0x1000) // minimapPosition
        body.append(uint16LE: 0x1020) // selectionRectanglePosition
        body.append(int8: -1)      // selectionType
        body.append(int8: 7)       // structureActiveType (int8 on disk)
        body.append(uint16LE: 0x1030) // structureActivePosition
        body.append(uint16LE: 5)   // structureActiveIndex
        body.append(uint16LE: 0xFFFF) // unitSelectedIndex
        body.append(uint16LE: 11)  // unitActiveIndex
        body.append(uint16LE: 2)   // activeAction
        body.append(uint32LE: 0x0000_00FF) // strategicRegionBits
        body.append(uint16LE: 5)   // scenarioID
        body.append(uint16LE: 2)   // campaignID
        body.append(uint32LE: 0xDEAD_BEEF) // hintsShown1
        body.append(uint32LE: 0xCAFE_BABE) // hintsShown2
        body.append(uint32LE: 7_777)       // scenarioElapsedTicks
        body.append(uint16LE: 999) // DUPLICATE playerCreditsNoSilo
        for i in 0..<27 {
            body.append(int16LE: Int16(i) - 1) // starport[0] = -1, [1] = 0, ...
        }
        body.append(uint16LE: 300) // houseMissileCountdown
        body.append(uint16LE: 0xFFFF) // unitHouseMissileIndex
        body.append(uint16LE: 42)  // structureIndex

        #expect(body.count == 330)

        let info = try Formats.Save.Info.decode(body)
        #expect(info.version == 0x0290)

        // Scenario nested
        #expect(info.scenario.score == 1_234)
        #expect(info.scenario.winFlags == 0x0001)
        #expect(info.scenario.loseFlags == 0x0002)
        #expect(info.scenario.mapSeed == 0x1234_5678)
        #expect(info.scenario.mapScale == 3)
        #expect(info.scenario.timeOut == 65_000)
        #expect(info.scenario.pictureBriefing == "BRIEFPIC")
        #expect(info.scenario.pictureWin == "WINPIC")
        #expect(info.scenario.pictureLose == "LOSEPIC")
        #expect(info.scenario.killedAllied == 10)
        #expect(info.scenario.destroyedEnemy == 40)
        #expect(info.scenario.harvestedAllied == 500)
        #expect(info.scenario.reinforcement.count == 16)
        #expect(info.scenario.reinforcement[0].unitID == 7)
        #expect(info.scenario.reinforcement[0].locationID == 3)
        #expect(info.scenario.reinforcement[0].timeLeft == 1000)
        #expect(info.scenario.reinforcement[0].timeBetween == 250)
        #expect(info.scenario.reinforcement[0].repeats == 1)
        #expect(info.scenario.reinforcement[1].unitID == 0xFFFF)

        // Top-level
        #expect(info.playerCreditsNoSilo == 999)
        #expect(info.minimapPosition == 0x1000)
        #expect(info.selectionRectanglePosition == 0x1020)
        #expect(info.selectionType == -1)
        #expect(info.structureActiveType == 7)
        #expect(info.structureActivePosition == 0x1030)
        #expect(info.structureActiveIndex == 5)
        #expect(info.unitSelectedIndex == 0xFFFF)
        #expect(info.unitActiveIndex == 11)
        #expect(info.activeAction == 2)
        #expect(info.strategicRegionBits == 0x0000_00FF)
        #expect(info.scenarioID == 5)
        #expect(info.campaignID == 2)
        #expect(info.hintsShown1 == 0xDEAD_BEEF)
        #expect(info.hintsShown2 == 0xCAFE_BABE)
        #expect(info.scenarioElapsedTicks == 7_777)
        #expect(info.starportAvailable.count == 27)
        #expect(info.starportAvailable[0] == -1)
        #expect(info.starportAvailable[1] == 0)
        #expect(info.starportAvailable[26] == 25)
        #expect(info.houseMissileCountdown == 300)
        #expect(info.unitHouseMissileIndex == 0xFFFF)
        #expect(info.structureIndex == 42)
    }

    @Test("second playerCreditsNoSilo wins when bodies disagree (duplicate-field quirk)")
    func duplicateCreditsSecondWins() throws {
        var body = makeInfoBody(firstCredits: 123, secondCredits: 456)
        #expect(body.count == 330)
        let info = try Formats.Save.Info.decode(body)
        #expect(info.playerCreditsNoSilo == 456)

        // Sanity: swapping the two bytes flips the result.
        body.replaceSubrange(2 + 228 ..< 2 + 228 + 2, with: uint16LEBytes(999))
        let info2 = try Formats.Save.Info.decode(body)
        #expect(info2.playerCreditsNoSilo == 456) // second still wins
    }

    // MARK: Failure modes

    @Test("wrong version is surfaced, not silently accepted")
    func wrongVersion() throws {
        var body = makeInfoBody(firstCredits: 0, secondCredits: 0)
        body[0] = 0x00
        body[1] = 0x00
        #expect(throws: Formats.Save.Info.DecodeError.self) {
            _ = try Formats.Save.Info.decode(body)
        }
        do {
            _ = try Formats.Save.Info.decode(body)
            Issue.record("expected legacyVersion error")
        } catch let Formats.Save.Info.DecodeError.legacyVersion(v) {
            #expect(v == 0x0000)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("truncated chunk is rejected")
    func truncatedChunk() {
        let body = Data([0x90, 0x02, 0x00, 0x00]) // version + 2 bytes
        #expect(throws: Formats.Save.Info.DecodeError.truncated) {
            _ = try Formats.Save.Info.decode(body)
        }
    }

    // MARK: Real data

    @Test("_SAVE001.DAT INFO chunk decodes into a plausible mission header")
    func realSave001Info() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        guard let infoBody = container.chunk(named: "INFO") else {
            Issue.record("INFO chunk missing"); return
        }

        // Body must be the modern 330-byte size (version word + 328-byte table).
        #expect(infoBody.count == 330)

        let info = try Formats.Save.Info.decode(infoBody)

        #expect(info.version == 0x0290)
        #expect((1...22).contains(info.scenarioID))
        // campaignID is 0 before house selection and up through 9 at the end
        // of a campaign — both the start-of-game save and a completed run are
        // legitimate values for `_SAVE001.DAT`.
        #expect((0...9).contains(info.campaignID))
        // Map seed comes from the scenario and is what `Map_CreateLandscape` uses.
        #expect(info.scenario.mapSeed != 0)
        // Starport array is either `-1` (unknown) or a small positive stock.
        for stock in info.starportAvailable {
            #expect(stock == -1 || (0...99).contains(stock))
        }
        // Picture filenames should be printable ASCII + NUL padding.
        for ch in info.scenario.pictureBriefing.utf8 {
            #expect((0x20...0x7E).contains(ch))
        }
    }
}

// MARK: - Helpers

private func makeInfoBody(firstCredits: UInt16, secondCredits: UInt16) -> Data {
    // Buffer layout: [0..2) version · [2..230) scenario · [230..232) firstCredits
    // · [232..268) 36 bytes of intermediate fields · [268..270) secondCredits
    // · [270..330) remaining 60 bytes (starport 54 + missile/unit/structure 6).
    var body = Data()
    body.append(uint16LE: 0x0290)
    body.append(Data(count: 228))
    body.append(uint16LE: firstCredits)
    body.append(Data(count: 268 - 232))
    body.append(uint16LE: secondCredits)
    body.append(Data(count: 330 - 270))
    precondition(body.count == 330)
    return body
}

private func uint16LEBytes(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
}

private func appendCString(_ data: inout Data, _ s: String, totalLen: Int) {
    var bytes = Array(s.utf8)
    precondition(bytes.count < totalLen)
    bytes.append(0) // NUL
    while bytes.count < totalLen { bytes.append(0) }
    data.append(contentsOf: bytes)
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
    mutating func append(int8 value: Int8) {
        append(UInt8(bitPattern: value))
    }
}
