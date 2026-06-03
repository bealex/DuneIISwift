import DuneIIContracts
import Testing

@testable import DuneIIWorld

/// `ScenarioID` — parsing a `SCEN<House><NNN>.INI` file name into house / mission / campaign level, and the
/// Dune II mission→campaign grouping the scenario picker uses.
@Suite("Scenario catalog")
struct ScenarioCatalogTests {
    @Test("parses the house initial, mission number, and campaign level (case-insensitive)")
    func parse() throws {
        let a1 = try #require(ScenarioID(fileName: "SCENA001.INI"))
        #expect(a1.house == .atreides)
        #expect(a1.mission == 1)
        #expect(a1.campaign == 1)
        #expect(a1.fileName == "SCENA001.INI")
        #expect(ScenarioID(fileName: "scenh005.ini")?.house == .harkonnen)  // case-insensitive
        let o22 = try #require(ScenarioID(fileName: "SCENO022.INI"))
        #expect(o22.house == .ordos && o22.mission == 22)
    }

    @Test("campaign grouping: mission 1 alone, then three scenarios per level")
    func campaignGrouping() {
        #expect(ScenarioID.campaign(forMission: 1) == 1)
        #expect(ScenarioID.campaign(forMission: 2) == 2)
        #expect(ScenarioID.campaign(forMission: 4) == 2)
        #expect(ScenarioID.campaign(forMission: 5) == 3)
        #expect(ScenarioID.campaign(forMission: 7) == 3)
        #expect(ScenarioID.campaign(forMission: 8) == 4)
        #expect(ScenarioID.campaign(forMission: 22) == 8)
    }

    @Test("rejects non-scenario file names")
    func rejects() {
        #expect(ScenarioID(fileName: "REGIONA.INI") == nil)  // region map, not a scenario
        #expect(ScenarioID(fileName: "ICON.MAP") == nil)
        #expect(ScenarioID(fileName: "SCENA.INI") == nil)  // no mission number
    }
}
