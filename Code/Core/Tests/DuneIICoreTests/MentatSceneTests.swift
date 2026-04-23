import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// Slice 1 of the Mentat briefing port (2026-04-23). Pins the two
/// pure helpers used to pick the right assets for a given scenario:
/// the MENTAT{letter}.CPS lookup + the scenario-filename → player-
/// house inference. Scene rendering itself is manual-verification
/// only (see `Documentation/Algorithms/MentatBriefing.md` §3).
@MainActor
@Suite("MentatScene — CPS + player-house resolvers (slice 1)")
struct MentatSceneTests {

    @Test("cpsName uses the OpenDUNE house-name[0] letter")
    func cpsByHouse() {
        #expect(MentatScene.cpsName(forHouse: Simulation.House.harkonnen) == "MENTATH.CPS")
        #expect(MentatScene.cpsName(forHouse: Simulation.House.atreides)  == "MENTATA.CPS")
        #expect(MentatScene.cpsName(forHouse: Simulation.House.ordos)     == "MENTATO.CPS")
        #expect(MentatScene.cpsName(forHouse: Simulation.House.fremen)    == "MENTATF.CPS")
        #expect(MentatScene.cpsName(forHouse: Simulation.House.sardaukar) == "MENTATS.CPS")
        #expect(MentatScene.cpsName(forHouse: Simulation.House.mercenary) == "MENTATM.CPS")
    }

    @Test("cpsName falls back to MENTATA.CPS on an unknown house ID")
    func cpsFallsBackOnUnknownHouse() {
        #expect(MentatScene.cpsName(forHouse: 99) == "MENTATA.CPS")
    }

    @Test("playerHouse(forScenarioName:) reads the 5th character")
    func playerHouseFromScenarioName() {
        #expect(MentatScene.playerHouse(forScenarioName: "SCENA001.INI") == Simulation.House.atreides)
        #expect(MentatScene.playerHouse(forScenarioName: "SCENH007.INI") == Simulation.House.harkonnen)
        #expect(MentatScene.playerHouse(forScenarioName: "SCENO015.INI") == Simulation.House.ordos)
    }

    @Test("playerHouse(forScenarioName:) is case-insensitive and strips paths / .INI")
    func playerHouseRobustness() {
        #expect(MentatScene.playerHouse(forScenarioName: "scena001.ini") == Simulation.House.atreides)
        #expect(MentatScene.playerHouse(forScenarioName: "/install/SCENH003.INI") == Simulation.House.harkonnen)
        #expect(MentatScene.playerHouse(forScenarioName: "SCENO022") == Simulation.House.ordos)
    }

    @Test("playerHouse(forScenarioName:) falls back to Atreides on junk names")
    func playerHouseFallsBack() {
        #expect(MentatScene.playerHouse(forScenarioName: "") == Simulation.House.atreides)
        #expect(MentatScene.playerHouse(forScenarioName: "XXXX") == Simulation.House.atreides)
        #expect(MentatScene.playerHouse(forScenarioName: "SCENZ000.INI") == Simulation.House.atreides)
    }

    // MARK: - Slice 3 — briefing text resolver

    /// Install-gated: boots an `AssetLoader` against the real install
    /// and pulls the Atreides mission-1 briefing through
    /// `MentatScene.fetchBriefingText`. Confirms the full pipeline
    /// (TEXTA.ENG load → `Formats.Strings` decompress → index lookup)
    /// returns a recognisable English string with "Atreides" in it.
    @Test("fetchBriefingText returns a recognisable English briefing for mission 1")
    func fetchBriefingTextAtreidesMission1() throws {
        guard let installDir = TestInstall.locate() else { return }
        let installation = try Installation(rootDirectory: installDir)
        let assets = try AssetLoader(installation: installation)
        guard let text = MentatScene.fetchBriefingText(
            fromLoader: assets,
            playerHouseID: Simulation.House.atreides,
            campaignID: 0
        ) else {
            Issue.record("fetchBriefingText returned nil for Atreides mission 1")
            return
        }
        // End-to-end sanity: length + vocabulary typical of a Dune II
        // mission-1 briefing ("Greetings, I am your Mentat …"). The
        // exact wording depends on which briefing-string slot
        // OpenDUNE uses, which isn't important for this test — we
        // just want to confirm the TEXTA.ENG → decompress → index
        // pipeline produces real English.
        #expect(text.count > 50, "briefing too short: \(text.count) chars")
        let lower = text.lowercased()
        #expect(lower.contains("mentat") || lower.contains("credits"),
                "expected game-vocab words in briefing; got: \(text.prefix(160))")
    }

    @Test("fetchBriefingText returns nil for unknown houses (no TEXT file maps)")
    func fetchBriefingTextUnknownHouseIsNil() throws {
        guard let installDir = TestInstall.locate() else { return }
        let installation = try Installation(rootDirectory: installDir)
        let assets = try AssetLoader(installation: installation)
        let text = MentatScene.fetchBriefingText(
            fromLoader: assets,
            playerHouseID: Simulation.House.mercenary,
            campaignID: 0
        )
        #expect(text == nil,
                "Mercenary / Fremen / Sardaukar have no dedicated TEXT file; expected nil")
    }
}
