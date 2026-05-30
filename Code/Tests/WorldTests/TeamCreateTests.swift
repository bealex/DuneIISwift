import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld

/// `Team_Create` (`team.c:75`) + the `[TEAMS]` scenario loader (`Scenario_Load_Team`) + the
/// movement/team-action string parsers.
@Suite("Team creation")
struct TeamCreateTests {
    @Test("teamCreate allocates + sets the identity/bounds and loads the action script")
    func createsTeam() throws {
        var s = GameState()
        let created = s.teamCreate(houseID: 1, teamActionType: UInt8(TeamActionType.kamikaze.rawValue),
                                   movementType: UInt8(MovementType.wheeled.rawValue),
                                   minMembers: 2, maxMembers: 5, scriptPC: 40)
        let slot = try #require(created)
        let t = s.teams[slot]
        #expect(t.flags.contains(.used))
        #expect(t.houseID == 1)
        #expect(t.action == UInt16(TeamActionType.kamikaze.rawValue))
        #expect(t.actionStart == t.action)                 // action == actionStart so Load2 can restore it
        #expect(t.movementType == UInt16(MovementType.wheeled.rawValue))
        #expect(t.minMembers == 2 && t.maxMembers == 5)
        #expect(t.script.scriptPC == 40)                   // Script_Load → offsets[teamActionType]
        #expect(t.script.delay == 0)
    }

    @Test("teamCreate with scriptNull leaves the team's script unloaded (inert)")
    func createsInertTeam() throws {
        var s = GameState()
        let created = s.teamCreate(houseID: 0, teamActionType: 0, movementType: 0,
                                   minMembers: 0, maxMembers: 1, scriptPC: ScriptEngine.scriptNull)
        let slot = try #require(created)
        #expect(s.teams[slot].script.scriptPC == ScriptEngine.scriptNull)
    }

    @Test("the movement / team-action string parsers match the OpenDUNE name tables")
    func stringParsers() {
        #expect(MovementType.named("Foot") == .foot)
        #expect(MovementType.named("wheeled") == .wheeled)   // case-insensitive
        #expect(MovementType.named("Winged") == .winger)     // "Winged" (string) → .winger (enum)
        #expect(MovementType.named("Nope") == nil)
        #expect(TeamActionType.named("Normal") == .normal)
        #expect(TeamActionType.named("kamikaze") == .kamikaze)
        #expect(TeamActionType.named("Guard") == .guard_)
        #expect(TeamActionType.named("xx") == nil)
    }

    @Test("loadScenario parses a [TEAMS] section into Team_Create calls with the action's script offset")
    func loadsTeamsSection() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = Ini(text: """
        [BASIC]
        MapScale=1
        [MAP]
        Seed=1
        [TEAMS]
        Team1=Harkonnen,Kamikaze,Wheeled,2,5
        Team2=Ordos,Guard,Foot,1,3
        """)

        var state = GameState()
        // Per-action entry offsets (the team ScriptInfo's `offsets`): action N → offsets[N].
        state.loadScenario(ini: ini, iconMap: iconMap, teamScriptOffsets: [10, 20, 30, 40, 50])

        let teams = state.teams.indices.filter { state.teams[$0].flags.contains(.used) }.map { state.teams[$0] }
        #expect(teams.count == 2)
        let kamikaze = try #require(teams.first { $0.action == UInt16(TeamActionType.kamikaze.rawValue) })
        #expect(kamikaze.houseID == UInt8(HouseID.harkonnen.rawValue))
        #expect(kamikaze.movementType == UInt16(MovementType.wheeled.rawValue))
        #expect(kamikaze.minMembers == 2 && kamikaze.maxMembers == 5)
        #expect(kamikaze.script.scriptPC == 40)            // offsets[Kamikaze=3]
        let guardTeam = try #require(teams.first { $0.action == UInt16(TeamActionType.guard_.rawValue) })
        #expect(guardTeam.houseID == UInt8(HouseID.ordos.rawValue))
        #expect(guardTeam.movementType == UInt16(MovementType.foot.rawValue))
        #expect(guardTeam.script.scriptPC == 50)           // offsets[Guard=4]
    }
}
