import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Simulation.ParityHarness")
struct ParityHarnessTests {

    // MARK: Golden JSONL parsing

    @Test("parseGolden decodes a 2-line dump with all field names")
    func parseGoldenHappy() throws {
        let body = """
        {"tick":0,"houses":[],"structures":[],"units":[]}
        {"tick":1,"houses":[{"index":0,"credits":100,"creditsStorage":1000,"creditsQuota":0,"powerProduction":0,"powerUsage":0,"unitCount":0,"unitCountMax":0,"harvestersIncoming":0,"starportTimeLeft":0,"starportLinkedID":65535}],"structures":[],"units":[]}
        """
        let ticks = try Simulation.ParityHarness.parseGolden(Data(body.utf8))
        #expect(ticks.count == 2)
        #expect(ticks[0].tick == 0)
        #expect(ticks[1].houses.first?.credits == 100)
        #expect(ticks[1].houses.first?.starportLinkedID == 65535)
    }

    @Test("parseGolden rejects malformed JSON with line index")
    func parseGoldenMalformed() {
        let body = """
        {"tick":0,"houses":[],"structures":[],"units":[]}
        {"tick":1,"houses":[
        """
        do {
            _ = try Simulation.ParityHarness.parseGolden(Data(body.utf8))
            Issue.record("expected goldenLineMalformed")
        } catch let err as Simulation.ParityHarness.ParseError {
            if case .goldenLineMalformed(let idx, _) = err {
                #expect(idx == 1)
            } else {
                Issue.record("unexpected case: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Real golden against _SAVE001.DAT

    /// Pins tick 0 of the committed golden against `WorldSnapshot(loading:)`.
    /// Tick 0 is the *post-save-load, pre-first-tick* state — both engines
    /// see the same bytes, so any mismatch here means either a save-decoder
    /// bug or a golden-schema field we're incorrectly comparing.
    ///
    /// Stepping past tick 0 is expected to diverge immediately on our
    /// current sim (fog, sprite, RNG cascades are unported) — that's the
    /// signal we're meant to chase, not a pass/fail line.
    @Test("_SAVE001.DAT tick 0 matches the committed 200-tick golden")
    @MainActor
    func saveOneParityTickZero() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE001.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }

        let goldenURL = Self.goldenURL(named: "save001_200ticks.jsonl")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        // Pool-state parity only; tile grid isn't in the golden schema yet,
        // so Map.empty() sidesteps Map.Generator for this test.
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
        let golden = try Data(contentsOf: goldenURL)

        // tickLimit = 0 → diff tick 0 only, no scheduler.tick() calls.
        // Any failure here is a pure save-decoder / schema bug.
        try Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 0
        )
    }

    /// Stepping past tick 0 with empty EMC programs is expected to
    /// diverge on today's sim — `GameLoop_Unit` / `GameLoop_Structure`
    /// on OpenDUNE side runs `UNIT.EMC` / `BUILD.EMC` while the
    /// harness default is `Formats.Emc.Program.empty`. This pins
    /// *where* the empty-EMC drift lands; the real-EMC variant below
    /// threads the install's programs through and captures the next
    /// frontier.
    @Test("_SAVE001.DAT tick 1 with empty EMC currently diverges")
    @MainActor
    func saveOneParityTickOneDiverges() throws {
        try expectTickOneDivergence(save: "_SAVE001.DAT", golden: "save001_200ticks.jsonl")
    }

    /// Same as `saveOneParityTickOneDiverges` but with real `UNIT.EMC`
    /// / `BUILD.EMC` / `TEAM.EMC` loaded via `AssetLoader`. Expected to
    /// still diverge (more sim surface is covered = more drift
    /// opportunities), just on a different field. The log line in the
    /// output pins whichever field is "next" to close.
    @Test("_SAVE001.DAT tick 1 with real UNIT.EMC / BUILD.EMC / TEAM.EMC")
    @MainActor
    func saveOneParityTickOneRealEmc() throws {
        try expectTickOneDivergence(
            save: "_SAVE001.DAT", golden: "save001_200ticks.jsonl",
            withRealEmc: true
        )
    }

    /// SAVE007 is a richer mid-mission save: harvester actively harvesting,
    /// one player trike attacking, four enemy infantry hunting, one bullet
    /// in flight by tick 14. Exercises more of the sim per tick than SAVE001
    /// so divergences surface faster and in wider variety. Tick 0 pins the
    /// save-loader contract; tick 1 captures the first active drift.
    @Test("_SAVE007.DAT tick 0 matches the committed 200-tick golden")
    @MainActor
    func saveSevenParityTickZero() throws {
        try runTickZeroAgainstGolden(save: "_SAVE007.DAT", golden: "save007_200ticks.jsonl")
    }

    @Test("_SAVE007.DAT tick 1 with empty EMC currently diverges")
    @MainActor
    func saveSevenParityTickOneDiverges() throws {
        try expectTickOneDivergence(save: "_SAVE007.DAT", golden: "save007_200ticks.jsonl")
    }

    @Test("_SAVE007.DAT tick 1 with real UNIT.EMC / BUILD.EMC / TEAM.EMC")
    @MainActor
    func saveSevenParityTickOneRealEmc() throws {
        try expectTickOneDivergence(
            save: "_SAVE007.DAT", golden: "save007_200ticks.jsonl",
            withRealEmc: true
        )
    }

    // MARK: Shared helpers

    @MainActor
    private func runTickZeroAgainstGolden(save: String, golden goldenName: String) throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent(save)
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: goldenName)
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
        let golden = try Data(contentsOf: goldenURL)

        try Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 0
        )
    }

    @MainActor
    private func expectTickOneDivergence(
        save: String,
        golden goldenName: String,
        withRealEmc: Bool = false
    ) throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent(save)
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: goldenName)
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
        let golden = try Data(contentsOf: goldenURL)

        var unitProgram = Formats.Emc.Program.empty
        var structureProgram = Formats.Emc.Program.empty
        var teamProgram = Formats.Emc.Program.empty
        let label: String
        if withRealEmc {
            let install = try Installation(rootDirectory: root)
            let assets = try AssetLoader(installation: install)
            unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
            structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
            teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
            label = "\(save)+UNIT.EMC"
        } else {
            label = "\(save)+empty-EMC"
        }

        do {
            try Simulation.ParityHarness.runAgainst(
                snapshot: snapshot,
                golden: golden,
                tickLimit: 1,
                unitProgram: unitProgram,
                structureProgram: structureProgram,
                teamProgram: teamProgram,
                seedScriptsFrom: withRealEmc ? game : nil
            )
            Issue.record("unexpected: tick 1 matched for \(label) — widen tickLimit and remove this expectation")
        } catch let d as Simulation.ParityHarness.Divergence {
            #expect(d.tick == 1)
            print("parity first drift (\(label)) at tick 1: \(d)")
        }
    }

    // MARK: Helpers

    private static func goldenURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ParityGoldens", isDirectory: true)
            .appendingPathComponent(name)
    }
}

