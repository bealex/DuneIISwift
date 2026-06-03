import DuneIIContracts

/// A campaign scenario file (`SCEN<House><NNN>.INI`) parsed into its house, mission number, and the campaign
/// (mission) level that gates its tech tree. The original picks scenarios via the strategic map per won
/// campaign, so there is no *engine* function from file number → campaign; we use Dune II's standard
/// grouping — mission 1 is campaign 1, then each later campaign offers three territory scenarios
/// (2–4 → campaign 2, 5–7 → 3, …). Used by the client's scenario picker (group by house, then campaign) and
/// to set `GameState.campaignID` on load so the build tree matches the mission.
public struct ScenarioID: Sendable, Equatable, Hashable {
    /// The canonical upper-cased file name, e.g. `SCENA001.INI`.
    public let fileName: String
    public let house: HouseID
    /// The 1-based number in the file name (1…22 in the shipped campaign).
    public let mission: Int
    /// The campaign level (OpenDUNE `g_campaignID`, 1…9) this scenario is played at — gates build
    /// availability + the upgrade chain (`Structure_GetBuildable`).
    public let campaign: Int

    public init?(fileName: String) {
        let upper = fileName.uppercased()
        guard upper.hasPrefix("SCEN"), upper.hasSuffix(".INI") else { return nil }
        let core = upper.dropFirst(4).dropLast(4)  // "SCENA001.INI" → "A001"
        guard let initial = core.first, let mission = Int(core.dropFirst()), mission >= 1 else { return nil }
        guard
            let house = HouseID.allCases.first(where: { HouseInfo[$0].name.uppercased().first == initial })
        else {
            return nil
        }
        self.fileName = upper
        self.house = house
        self.mission = mission
        self.campaign = ScenarioID.campaign(forMission: mission)
    }

    /// Dune II's mission-number → campaign-level grouping: mission 1 is campaign 1; thereafter three
    /// scenarios per campaign (2–4 → 2, 5–7 → 3, …), capped at the final campaign 9.
    public static func campaign(forMission mission: Int) -> Int {
        guard mission > 1 else { return 1 }
        return min(9, (mission - 2) / 3 + 2)
    }
}
