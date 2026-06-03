import Foundation
import Testing

@testable import DuneIIWorld

/// Field-for-field parity of the static stat tables against OpenDUNE's `g_table_*`, from the per-table
/// golden fixtures. (HouseInfo has its own suite; this covers landscape + action.)
@Suite("Stat table golden parity")
struct StatTableGoldenTests {
    struct LandscapeRow: Decodable {
        let index: Int
        let movementSpeed: [UInt8]
        let letUnitWobble: Int
        let isValidForStructure: Int
        let isSand: Int
        let isValidForStructure2: Int
        let canBecomeSpice: Int
        let craterType: UInt8
        let radarColour: UInt16
        let spriteID: UInt16
    }

    struct ActionRow: Decodable {
        let index: Int
        let stringID: UInt16
        let name: String
        let switchType: UInt16
        let selectionType: Int
        let soundID: UInt16
    }

    struct LayoutRow: Decodable {
        let index: Int
        let tiles: [UInt16]
        let edgeTiles: [UInt16]
        let tileCount: UInt16
        let tileDiffX: UInt16
        let tileDiffY: UInt16
        let sizeWidth: UInt16
        let sizeHeight: UInt16
        let tilesAround: [Int16]
    }

    @Test("g_table_landscapeInfo matches for every landscape type")
    func landscape() throws {
        let rows = GoldenFixture.decode("landscapeinfo-golden.jsonl", as: LandscapeRow.self)
        #expect(rows.count == LandscapeType.allCases.count)
        for row in rows {
            let type = try #require(LandscapeType(rawValue: row.index))
            let info = LandscapeInfo[type]
            #expect(info.movementSpeed == row.movementSpeed)
            #expect(info.letUnitWobble == (row.letUnitWobble != 0))
            #expect(info.isValidForStructure == (row.isValidForStructure != 0))
            #expect(info.isSand == (row.isSand != 0))
            #expect(info.isValidForStructure2 == (row.isValidForStructure2 != 0))
            #expect(info.canBecomeSpice == (row.canBecomeSpice != 0))
            #expect(info.craterType == row.craterType)
            #expect(info.radarColour == row.radarColour)
            #expect(info.spriteID == row.spriteID)
        }
    }

    @Test("g_table_actionInfo matches for every action type")
    func action() throws {
        let rows = GoldenFixture.decode("actioninfo-golden.jsonl", as: ActionRow.self)
        #expect(rows.count == ActionType.allCases.count)
        for row in rows {
            let type = try #require(ActionType(rawValue: row.index))
            let info = ActionInfo[type]
            #expect(info.stringID == row.stringID)
            #expect(info.name == row.name)
            #expect(info.switchType == row.switchType)
            #expect(info.selectionType.rawValue == row.selectionType)
            #expect(info.soundID == row.soundID)
        }
    }

    @Test("g_table_structure_layout matches for every layout")
    func structureLayout() throws {
        let rows = GoldenFixture.decode("structurelayout-golden.jsonl", as: LayoutRow.self)
        #expect(rows.count == 7)
        for row in rows {
            let layout = try #require(StructureLayout(rawValue: row.index))
            let info = StructureLayoutInfo[layout]
            #expect(info.tiles == row.tiles)
            #expect(info.edgeTiles == row.edgeTiles)
            #expect(info.tileCount == row.tileCount)
            #expect(info.tileDiff == Tile32(x: row.tileDiffX, y: row.tileDiffY))
            #expect(info.size == XYSize(width: row.sizeWidth, height: row.sizeHeight))
            #expect(info.tilesAround == row.tilesAround)
        }
    }

    @Test("g_table_actionsAI matches")
    func actionsAI() {
        let out = GoldenFixture.records("actionsai-golden.jsonl", fn: "g_table_actionsAI")[0].out.values
        #expect(ActionInfo.actionsAI.map { $0.rawValue } == out)
    }
}
