import DuneIIContracts
import Foundation
import Testing

@testable import DuneIIWorld

/// Field-for-field parity of `HouseInfo.table` against OpenDUNE's `g_table_houseInfo[]`, from the
/// golden fixture `houseinfo-golden.jsonl`.
@Suite("HouseInfo golden parity")
struct HouseInfoGoldenTests {
    struct Row: Decodable {
        let index: Int
        let name: String
        let toughness: UInt16
        let degradingChance: UInt16
        let degradingAmount: UInt16
        let minimapColor: UInt16
        let specialCountDown: UInt16
        let starportDeliveryTime: UInt16
        let prefixChar: UInt16
        let specialWeapon: UInt16
        let musicWin: UInt16
        let musicLose: UInt16
        let musicBriefing: UInt16
        let voiceFilename: String
    }

    @Test("g_table_houseInfo matches for every house")
    func table() throws {
        let rows = GoldenFixture.decode("houseinfo-golden.jsonl", as: Row.self)
        #expect(rows.count == HouseID.allCases.count)
        for row in rows {
            let house = try #require(HouseID(rawValue: row.index))
            let info = HouseInfo[house]
            #expect(info.name == row.name)
            #expect(info.toughness == row.toughness)
            #expect(info.degradingChance == row.degradingChance)
            #expect(info.degradingAmount == row.degradingAmount)
            #expect(info.minimapColor == row.minimapColor)
            #expect(info.specialCountDown == row.specialCountDown)
            #expect(info.starportDeliveryTime == row.starportDeliveryTime)
            #expect(info.prefixChar == row.prefixChar)
            #expect(info.specialWeapon == row.specialWeapon)
            #expect(info.musicWin == row.musicWin)
            #expect(info.musicLose == row.musicLose)
            #expect(info.musicBriefing == row.musicBriefing)
            #expect(info.voiceFilename == row.voiceFilename)
        }
    }
}
