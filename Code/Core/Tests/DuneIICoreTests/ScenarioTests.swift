import Foundation
import Testing
@testable import DuneIICore

@Suite("Scenario")
struct ScenarioTests {
    @Test("packed position unpacks to correct tile coords")
    func packedPosition() {
        // 1630 = 25 * 64 + 30 → (x: 30, y: 25)
        let pos = PackedPosition(raw: 1630)
        #expect(pos.tile.x == 30)
        #expect(pos.tile.y == 25)
        // Round-trip via the initialiser that takes tile coords.
        #expect(PackedPosition(x: 30, y: 25).raw == 1630)
    }

    @Test("synthetic scenario: basic, map, houses, units, structures")
    func syntheticScenario() throws {
        let src = """
        [BASIC]
        LosePicture=LOSTBILD.WSA
        WinPicture=WIN1.WSA
        BriefPicture=HARVEST.WSA
        TimeOut=0
        MapScale=1
        LoseFlags=4
        WinFlags=6

        [MAP]
        Field=1300,1510
        Bloom=2409
        Seed=353

        [Atreides]
        Quota=1000
        Credits=1000
        Brain=Human
        MaxUnit=25

        [Ordos]
        Quota=0
        Credits=0
        Brain=CPU
        MaxUnit=16

        [UNITS]
        ID038=Ordos,Soldier,256,1246,64,Ambush
        ID037=Atreides,Trike,256,1501,224,Guard

        [STRUCTURES]
        ID000=Atreides,Const Yard,256,1630
        """
        let scenario = try Scenario(iniData: Data(src.utf8))

        #expect(scenario.briefing.winPicture == "WIN1.WSA")
        #expect(scenario.briefing.losePicture == "LOSTBILD.WSA")
        #expect(scenario.briefing.briefPicture == "HARVEST.WSA")
        #expect(scenario.briefing.timeOut == 0)
        #expect(scenario.briefing.winFlags == 6)

        #expect(scenario.mapField.seed == 353)
        #expect(scenario.mapField.initialBlooms == [2409])
        #expect(scenario.mapField.initialSpiceFields == [1300, 1510])

        let atreides = scenario.houses[.atreides]
        #expect(atreides?.credits == 1000)
        #expect(atreides?.quota == 1000)
        #expect(atreides?.brain == .human)
        #expect(atreides?.maxUnits == 25)

        let ordos = scenario.houses[.ordos]
        #expect(ordos?.brain == .cpu)

        #expect(scenario.units.count == 2)
        let u0 = scenario.units[0]
        #expect(u0.house == .ordos)
        #expect(u0.unitType == .soldier)
        #expect(u0.hitPoints == 256)
        #expect(u0.position.raw == 1246)
        #expect(u0.orientation == 64)
        #expect(u0.action == .ambush)

        let u1 = scenario.units[1]
        #expect(u1.unitType == .trike)
        #expect(u1.action == .guard_)

        #expect(scenario.structures.count == 1)
        let s = scenario.structures[0]
        #expect(s.house == .atreides)
        #expect(s.structureType == .constructionYard)
        #expect(s.position.raw == 1630)
    }

    @Test("unknown house raises an error")
    func unknownHouse() {
        let src = """
        [BASIC]
        TimeOut=0

        [UNITS]
        ID000=Martians,Soldier,256,100,0,Guard
        """
        #expect(throws: Scenario.LoadError.self) {
            _ = try Scenario(iniData: Data(src.utf8))
        }
    }

    @Test("unknown unit type raises an error")
    func unknownUnitType() {
        let src = """
        [BASIC]
        TimeOut=0

        [UNITS]
        ID000=Atreides,Hovertank,256,100,0,Guard
        """
        #expect(throws: Scenario.LoadError.self) {
            _ = try Scenario(iniData: Data(src.utf8))
        }
    }

    @Test("wall/concrete placement via GEN-prefix keys is flagged as generated")
    func genPrefixStructure() throws {
        let src = """
        [BASIC]
        TimeOut=0

        [STRUCTURES]
        GEN1234=Atreides,Concrete Slab,256
        ID000=Atreides,Const Yard,256,1630
        """
        let scenario = try Scenario(iniData: Data(src.utf8))
        #expect(scenario.structures.count == 2)
        let gen = scenario.structures.first(where: { $0.isGenerated })
        #expect(gen != nil)
        #expect(gen?.position.raw == 1234)
    }

    @Test("real SCENA001.INI loads with the expected shape")
    func realScenario() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("SCENARIO.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "SCENA001.INI") else { return }
        let scenario = try Scenario(iniData: body)

        #expect(scenario.briefing.winPicture == "WIN1.WSA")
        #expect(scenario.houses[.atreides]?.credits == 1000)
        #expect(scenario.units.count >= 10)
        #expect(scenario.structures.count >= 1)
    }
}
