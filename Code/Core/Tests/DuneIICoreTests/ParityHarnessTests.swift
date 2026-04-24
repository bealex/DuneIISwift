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
        {"tick":0,"gameSpeed":2,"viewportPosition":0,"houses":[],"structures":[],"units":[]}
        {"tick":1,"gameSpeed":2,"viewportPosition":0,"houses":[{"index":0,"credits":100,"creditsStorage":1000,"creditsQuota":0,"powerProduction":0,"powerUsage":0,"unitCount":0,"unitCountMax":0,"harvestersIncoming":0,"starportTimeLeft":0,"starportLinkedID":65535}],"structures":[],"units":[]}
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
        {"tick":0,"gameSpeed":2,"viewportPosition":0,"houses":[],"structures":[],"units":[]}
        {"tick":1,"gameSpeed":2,"viewportPosition":0,"houses":[
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

    /// SAVE007 tick 1 now matches byte-for-byte under real UNIT.EMC /
    /// BUILD.EMC / TEAM.EMC (closed in the team-cadence + recount +
    /// Fire-jitter + harvester-sprite fix slice). This test widens the
    /// harness past tick 1 to surface the next drift; adjust `tickLimit`
    /// as closures move the frontier deeper into the golden.
    @Test("_SAVE007.DAT tick 1+ with real UNIT.EMC / BUILD.EMC / TEAM.EMC")
    @MainActor
    func saveSevenParityRealEmcFrontier() throws {
        try expectDivergenceUpTo(
            tickLimit: 200,
            save: "_SAVE007.DAT", golden: "save007_200ticks.jsonl",
            withRealEmc: true
        )
    }

    /// One-off diagnostic: writes the Swift Tools_Random_256 byte
    /// stream for SAVE007 tick 1 to the worktree `tmp/` directory so
    /// a byte-for-byte diff against OpenDUNE's matching trace pins the
    /// remaining u39.amount RNG-sequence offset. Gated on the install
    /// being present + the tmp dir existing; no assertions.
    @Test("_SAVE007.DAT tick 1 — dump Swift Tools_Random_256 byte stream")
    @MainActor
    func saveSevenParityTickOneDumpRandomStream() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_200ticks.jsonl")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        // Write to the worktree `tmp/` so the harness's file I/O doesn't
        // hit sandbox restrictions on `/tmp`. `#filePath` points to this
        // file; 5 deletingLastPathComponent hops up lands on the
        // worktree root (Code/Core/Tests/DuneIICoreTests → worktree).
        let tmpDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DuneIICoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Core/
            .deletingLastPathComponent()  // Code/
            .deletingLastPathComponent()  // <worktree-root>/
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
        let traceURL = tmpDir.appendingPathComponent("swift_rng_trace.txt")

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let golden = try Data(contentsOf: goldenURL)

        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
        let structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
        let teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
        let resolver = assets.tileResolver
        let baseline = Map.Generator.generate(
            seed: game.info.scenario.mapSeed, resolver: resolver
        )
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        let snapshotLandscape = snapshot.tiles.map { tile in
            resolver.landscapeType(
                groundTileID: tile.groundTileID,
                overlayTileID: tile.overlayTileID,
                hasStructure: tile.hasStructure
            )
        }
        let spiceMap = Simulation.SpiceMap { i in snapshotLandscape[i] }

        let trace = Simulation.ParityHarness.RNGTrace(path: traceURL)
        // Run — will throw on first divergence, which is fine; we still
        // want the partial trace up to that point to diff against
        // OpenDUNE's.
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 1,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            rngTrace: trace
        )
        // Diff-against-OpenDUNE is manual for now; the trace is on disk.
        print("wrote Swift rng trace to \(traceURL.path)")
    }

    /// Diagnostic: writes Swift's per-opcode execution trace for a
    /// single unit (default `u0`, the SAVE007 player carryall) over
    /// the first 100 ticks to `tmp/swift_u0_script.txt`. Pairs with
    /// OpenDUNE's `--parity-script-unit=0` dump at
    /// `tmp/opendune_u0_script.txt`; a line-by-line diff pins the
    /// tick where our VM takes a different branch. Gated on the
    /// install + golden being present; no assertions.
    @Test("_SAVE007.DAT — dump Swift u0 per-opcode script trace")
    @MainActor
    func saveSevenParityDumpU0ScriptTrace() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_200ticks.jsonl")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        let tmpDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
        let traceURL = tmpDir.appendingPathComponent("swift_u0_script.txt")

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let golden = try Data(contentsOf: goldenURL)

        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
        let structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
        let teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
        let resolver = assets.tileResolver
        let baseline = Map.Generator.generate(
            seed: game.info.scenario.mapSeed, resolver: resolver
        )
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        let snapshotLandscape = snapshot.tiles.map { tile in
            resolver.landscapeType(
                groundTileID: tile.groundTileID,
                overlayTileID: tile.overlayTileID,
                hasStructure: tile.hasStructure
            )
        }
        let spiceMap = Simulation.SpiceMap { i in snapshotLandscape[i] }

        let trace = Simulation.ParityHarness.ScriptTrace(
            path: traceURL, unitPoolIndex: 0
        )
        // Run over 100 ticks — covers the tick-96 carryall branch
        // point where OpenDUNE's pc jumps from 1117 → 1968. The
        // harness halts on the first field drift (currently tick
        // 151, u39.amount) so the trace is partial; that's fine
        // because the divergence we're chasing lands at tick 96.
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 100,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            scriptTrace: trace
        )
        print("wrote Swift u0 script trace to \(traceURL.path)")
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

    /// Run the parity harness with a widening `tickLimit` and
    /// record the first divergence anywhere in `[1..tickLimit]`.
    /// Unlike `expectTickOneDivergence`, this accepts divergences at
    /// any tick — useful once tick 1 is clean and the frontier moves
    /// deeper. Still expects *some* divergence within the window; if
    /// the entire run matches, the test records an Issue so we bump
    /// `tickLimit` further.
    @MainActor
    private func expectDivergenceUpTo(
        tickLimit: Int,
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
        let golden = try Data(contentsOf: goldenURL)

        var unitProgram = Formats.Emc.Program.empty
        var structureProgram = Formats.Emc.Program.empty
        var teamProgram = Formats.Emc.Program.empty
        let label: String
        var snapshot: Simulation.WorldSnapshot
        var spiceMap: Simulation.SpiceMap?
        var snapshotLandscape: [LandscapeType] = []
        if withRealEmc {
            let install = try Installation(rootDirectory: root)
            let assets = try AssetLoader(installation: install)
            unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
            structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
            teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
            let resolver = assets.tileResolver
            let baseline = Map.Generator.generate(
                seed: game.info.scenario.mapSeed, resolver: resolver
            )
            snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
            snapshotLandscape = snapshot.tiles.map { tile in
                resolver.landscapeType(
                    groundTileID: tile.groundTileID,
                    overlayTileID: tile.overlayTileID,
                    hasStructure: tile.hasStructure
                )
            }
            spiceMap = Simulation.SpiceMap { i in snapshotLandscape[i] }
            label = "\(save)+UNIT.EMC"
        } else {
            snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
            label = "\(save)+empty-EMC"
        }

        do {
            try Simulation.ParityHarness.runAgainst(
                snapshot: snapshot,
                golden: golden,
                tickLimit: tickLimit,
                unitProgram: unitProgram,
                structureProgram: structureProgram,
                teamProgram: teamProgram,
                seedScriptsFrom: withRealEmc ? game : nil,
                spiceMap: spiceMap,
                snapshotLandscape: snapshotLandscape
            )
            Issue.record("unexpected: \(label) matched through tick \(tickLimit) — widen tickLimit")
        } catch let d as Simulation.ParityHarness.Divergence {
            #expect(d.tick >= 1 && d.tick <= tickLimit)
            print("parity first drift (\(label)) at tick \(d.tick): \(d)")
        }
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
        let golden = try Data(contentsOf: goldenURL)

        var unitProgram = Formats.Emc.Program.empty
        var structureProgram = Formats.Emc.Program.empty
        var teamProgram = Formats.Emc.Program.empty
        let label: String
        var snapshot: Simulation.WorldSnapshot
        var spiceMap: Simulation.SpiceMap?
        var snapshotLandscape: [LandscapeType] = []
        if withRealEmc {
            let install = try Installation(rootDirectory: root)
            let assets = try AssetLoader(installation: install)
            unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
            structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
            teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
            // Real map baseline so the spiceMap reports actual landscape
            // (Script_Unit_Harvest reads this to decide "is the harvester
            // on a spice tile?"). `Map.empty()` leaves everything marked
            // `.notSand`, so the harvest function would always return 0.
            let resolver = assets.tileResolver
            let baseline = Map.Generator.generate(
                seed: game.info.scenario.mapSeed,
                resolver: resolver
            )
            snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
            // Pre-computed landscape lookup for every tile — feeds the
            // harness's `landscapeAt` closure (port of `Map_GetLandscapeType`).
            snapshotLandscape = snapshot.tiles.map { tile in
                resolver.landscapeType(
                    groundTileID: tile.groundTileID,
                    overlayTileID: tile.overlayTileID,
                    hasStructure: tile.hasStructure
                )
            }
            spiceMap = Simulation.SpiceMap { i in
                snapshotLandscape[i]
            }
            label = "\(save)+UNIT.EMC"
        } else {
            snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
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
                seedScriptsFrom: withRealEmc ? game : nil,
                spiceMap: spiceMap,
                snapshotLandscape: snapshotLandscape
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
