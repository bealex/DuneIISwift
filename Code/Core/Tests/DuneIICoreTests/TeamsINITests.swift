import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Scenario [TEAMS] parser + WorldSnapshot team spawn")
struct TeamsINITests {

    @Test("Scenario.TeamAction.typeID maps to OpenDUNE ActionType")
    func teamActionTypeIDs() {
        #expect(Scenario.TeamAction.normal.typeID == 0)
        #expect(Scenario.TeamAction.staging.typeID == 1)
        #expect(Scenario.TeamAction.flee.typeID == 2)
        #expect(Scenario.TeamAction.kamikaze.typeID == 3)
        #expect(Scenario.TeamAction.guard_.typeID == 4)
    }

    @Test("Scenario.TeamAction.parse is case-insensitive")
    func teamActionParse() {
        #expect(Scenario.TeamAction.parse("Normal") == .normal)
        #expect(Scenario.TeamAction.parse("kamikaze") == .kamikaze)
        #expect(Scenario.TeamAction.parse("Guard") == .guard_)
        #expect(Scenario.TeamAction.parse("unknown") == nil)
    }

    @Test("Parses a synthetic [TEAMS] section end-to-end")
    func parseTeamsSection() throws {
        let ini = """
            [BASIC]
            Seed=1
            MapScale=0
            [Atreides]
            Brain=Human
            [TEAMS]
            1=Ordos,Normal,Foot,2,4
            2=Harkonnen,Kamikaze,Tracked,4,6
            3=Sardaukar,Guard,Wheeled,3,5
            """
        let doc = try Formats.Ini.Document.decode(Data(ini.utf8))
        let scenario = try Scenario(document: doc)
        #expect(scenario.teams.count == 3)

        #expect(scenario.teams[0].house == .ordos)
        #expect(scenario.teams[0].action == .normal)
        #expect(scenario.teams[0].movementType == 0)    // foot
        #expect(scenario.teams[0].minMembers == 2)
        #expect(scenario.teams[0].maxMembers == 4)

        #expect(scenario.teams[1].house == .harkonnen)
        #expect(scenario.teams[1].action == .kamikaze)
        #expect(scenario.teams[1].movementType == 1)    // tracked

        #expect(scenario.teams[2].house == .sardaukar)
        #expect(scenario.teams[2].action == .guard_)
        #expect(scenario.teams[2].movementType == 3)    // wheeled
    }

    @Test("Missing [TEAMS] is fine — scenario.teams stays empty")
    func missingTeamsSection() throws {
        let ini = """
            [BASIC]
            Seed=1
            MapScale=0
            """
        let doc = try Formats.Ini.Document.decode(Data(ini.utf8))
        let scenario = try Scenario(document: doc)
        #expect(scenario.teams.isEmpty)
    }

    @Test("Malformed TEAMS row throws malformedRow")
    func malformedTeamsRow() throws {
        let ini = """
            [BASIC]
            Seed=1
            [TEAMS]
            1=Ordos,Normal
            """
        let doc = try Formats.Ini.Document.decode(Data(ini.utf8))
        #expect(throws: Scenario.LoadError.self) {
            _ = try Scenario(document: doc)
        }
    }

    @Test("WorldSnapshot allocates one TeamSlot per team spawn")
    func snapshotSpawnsTeams() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        // Mission 2 has 5 Ordos teams; mission 1 has none.
        guard let scenario2 = try assets.loadScenario(named: "SCENA002.INI") else { return }
        let snapshot = try Simulation.WorldSnapshot(
            scenario: scenario2, resolver: assets.tileResolver
        )
        #expect(snapshot.teams.findArray.count == scenario2.teams.count)
        #expect(scenario2.teams.count > 0, "mission 2 must carry [TEAMS]")
        // Each team carries the scenario's house + action + movement type.
        for (i, spawn) in scenario2.teams.enumerated() {
            let slot = snapshot.teams.slots[i]
            #expect(slot.isUsed)
            #expect(slot.houseID == spawn.house.typeID)
            #expect(slot.action == UInt16(spawn.action.typeID))
            #expect(slot.movementType == spawn.movementType)
            #expect(slot.minMembers == spawn.minMembers)
            #expect(slot.maxMembers == spawn.maxMembers)
        }
    }

    @Test("Mission 1 has no teams — snapshot.teams is empty")
    func missionOneHasNoTeams() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }
        #expect(scenario.teams.isEmpty)
        let snapshot = try Simulation.WorldSnapshot(
            scenario: scenario, resolver: assets.tileResolver
        )
        #expect(snapshot.teams.findArray.isEmpty)
    }
}
