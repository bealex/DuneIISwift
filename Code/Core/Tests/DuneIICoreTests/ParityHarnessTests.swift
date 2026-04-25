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
    @Test("_SAVE001.DAT tick 0 matches the 1000-tick golden")
    @MainActor
    func saveOneParityTickZero() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE001.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }

        let goldenURL = Self.goldenURL(named: "save001_ticks.jsonl")
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
        try expectTickOneDivergence(save: "_SAVE001.DAT", golden: "save001_ticks.jsonl")
    }

    /// Same as `saveOneParityTickOneDiverges` but with real `UNIT.EMC`
    /// / `BUILD.EMC` / `TEAM.EMC` loaded via `AssetLoader`. SAVE001
    /// historically diverged at tick 1 with `unit[22].actionID=5
    /// HARVEST vs 6 RETURN` (harvester transition class). The
    /// SearchSpice port (slot 0x29) closed that drift as a side-effect
    /// of fixing SAVE007 — the same harvester EMC path reads
    /// SearchSpice and falls through to RETURN when it returns 0.
    /// Widened to the full 1000-tick golden with landscape parity on
    /// top (same schema as SAVE007).
    @Test("_SAVE001.DAT FULL 1000-tick parity with real UNIT.EMC / BUILD.EMC / TEAM.EMC")
    @MainActor
    func saveOneParityRealEmc() throws {
        try expectFullParity(
            tickLimit: 1000,
            save: "_SAVE001.DAT", golden: "save001_ticks.jsonl",
            withRealEmc: true,
            compareLandscape: true
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
        try runTickZeroAgainstGolden(save: "_SAVE007.DAT", golden: "save007_ticks.jsonl")
    }

    @Test("_SAVE007.DAT tick 1 with empty EMC currently diverges")
    @MainActor
    func saveSevenParityTickOneDiverges() throws {
        try expectTickOneDivergence(save: "_SAVE007.DAT", golden: "save007_ticks.jsonl")
    }

    /// Dumps Swift u39's per-opcode trace for the tick-5261 RETURN
    /// drift investigation. Pair with an OpenDUNE
    /// `--parity-script-trace=tmp/opendune_u39_script.txt
    ///  --parity-script-unit=39 --parity-ticks=5300` run to diff the
    /// two engines' opcode streams; the first divergent opcode tells
    /// us which EMC branch read different state. No assertions —
    /// gated on the long golden being present.
    @Test("_SAVE007.DAT — dump Swift u39 per-opcode script trace")
    @MainActor
    func saveSevenParityDumpU39ScriptTrace() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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
        let traceURL = tmpDir.appendingPathComponent("swift_u39_script.txt")

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
            path: traceURL, unitPoolIndex: 39
        )
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 5267,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            scriptTrace: trace
        )
        print("wrote Swift u39 script trace to \(traceURL.path)")
    }

    /// Diagnostic for the tick-5261 `unit[39].actionID=6 RETURN vs 7
    /// STOP` frontier. Walks SAVE007 with `compareScriptPc: true` to
    /// find the FIRST tick where Swift's u39 script PC diverges from
    /// OpenDUNE's golden trajectory — well before the observable
    /// pool-state drift surfaces. The same observable state can be
    /// reached via slightly different opcode paths, so this test is
    /// expected to fire earlier (or at) tick 5261; the first PC
    /// divergence is the diagnostic payload, not a pass/fail line.
    /// Wires off by default in expectFullParity.
    @Test("_SAVE007.DAT scriptPc walk — find first PC divergence")
    @MainActor
    func saveSevenParityScriptPcFrontier() throws {
        try expectFullParity(
            tickLimit: 5435,
            save: "_SAVE007.DAT", golden: "save007_ticks.jsonl",
            withRealEmc: true,
            compareScriptPc: true,
            compareScriptPcUnit: 39
        )
    }

    /// Landscape-parity diagnostic for SAVE007. Widens the compare
    /// with per-tile `Map_GetLandscapeType` and walks forward until
    /// the first tile diverges. Wired to hunt the tick-3011
    /// `u39.targetMove` drift — the hypothesis is that Swift's spice
    /// map silently desynced from OpenDUNE's over thousands of ticks
    /// and `Script_General_SearchSpice` eventually reads a different
    /// tile on the two engines. Gated on the long (>3011 ticks)
    /// golden being present locally — short-circuits when it isn't.
    @Test("_SAVE007.DAT landscape parity — walk to first tile divergence")
    @MainActor
    func saveSevenParityLandscapeFrontier() throws {
        try expectFullParity(
            tickLimit: 5435,
            save: "_SAVE007.DAT", golden: "save007_ticks.jsonl",
            withRealEmc: true,
            compareLandscape: true
        )
    }

    /// 🎯 SAVE007 matches OpenDUNE byte-for-byte across the FULL
    /// 1000-tick golden under real UNIT.EMC / BUILD.EMC / TEAM.EMC.
    /// Closing this frontier required (across two same-day sessions):
    /// inline per-unit `fireDelay--` (`src/unit.c:202..216`);
    /// `Script_General_SearchSpice` (`src/script/general.c:325`) wired
    /// to a host closure that delegates to `Scheduler.findSpiceNear`;
    /// tie-break flip from `<` to `<=` in `findSpiceNear` to match
    /// OpenDUNE's last-wins ordering (`src/map.c:1162, 1171`); and
    /// the targetMove auto-clear in `tickMovement`'s arrival branch
    /// (`src/unit.c:1484..1486`).
    @Test("_SAVE007.DAT FULL 1000-tick parity with real UNIT.EMC / BUILD.EMC / TEAM.EMC")
    @MainActor
    func saveSevenParityRealEmcFrontier() throws {
        try expectFullParity(
            tickLimit: 1000,
            save: "_SAVE007.DAT", golden: "save007_ticks.jsonl",
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
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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

    /// Diagnostic: dump Swift's full `Tools_Random_256` byte stream
    /// across 200 ticks so `grep ctx=Harvest.bump` (or any other
    /// per-call context tag) can be scanned for when / whether a
    /// specific draw fires. Partners with the existing
    /// `saveSevenParityTickOneDumpRandomStream` which only covers
    /// tick 1. Pairs with OpenDUNE's matching `--parity-random-trace`
    /// dump when we can regenerate it.
    @Test("_SAVE007.DAT — dump Swift Tools_Random_256 byte stream over 200 ticks")
    @MainActor
    func saveSevenParityDump200TickRNGStream() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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
        let traceURL = tmpDir.appendingPathComponent("swift_rng_trace_200.txt")

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
        // `runAgainst` halts at the first drift; the RNGTrace flush
        // in its `defer` block still writes the partial trace. Bumped
        // to 695 to cover the tick-691 fireDelay drift investigation
        // window.
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 695,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            rngTrace: trace
        )
        print("wrote Swift 200-tick rng trace to \(traceURL.path)")
    }

    /// Diagnostic: writes Swift's `Tools_RandomLCG_Range` call stream
    /// over 200 ticks to `tmp/swift_lcg_trace_200.txt`. Pairs with
    /// OpenDUNE's `--parity-lcg-trace=<path>` output. Each line logs
    /// the returned value + per-call context tag (`IdleAction.gate uN`,
    /// `RandomRange(lo,hi)`, etc.) so a byte-stream diff pinpoints
    /// which caller diverges. Used to close the tick-166 LCG state
    /// drift (`u0.orientation0Target=43 vs 0`).
    @Test("_SAVE007.DAT — dump Swift Tools_RandomLCG_Range draws over 200 ticks")
    @MainActor
    func saveSevenParityDump200TickLCGStream() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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
        let traceURL = tmpDir.appendingPathComponent("swift_lcg_trace_200.txt")

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

        let trace = Simulation.ParityHarness.LCGTrace(path: traceURL)
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 200,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            lcgTrace: trace
        )
        print("wrote Swift 200-tick lcg trace to \(traceURL.path)")
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
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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
        // Run over 170 ticks — covers u0's tick-166 back-jump from
        // pc=2014 → pc=1981 where OpenDUNE fires
        // `Unit_SetOrientation(43, false, 0)`. Harness halts on first
        // field drift (currently tick 166, u0.orientation0Target=43
        // vs 0); the partial trace is the diagnostic payload.
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 170,
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

    /// Diagnostic for tick-551 drift: u37 is a HUNT trooper whose
    /// rotation completes at tick 551 in OpenDUNE, triggering
    /// `Unit_StartMovement` that writes `movingSpeed=255`. Swift's
    /// u37 reaches orientation target=32 but the script doesn't
    /// fire StartMovement. Writes per-opcode trace for u37 over 560
    /// ticks to `tmp/swift_u37_script.txt`; pair with an OpenDUNE
    /// `--parity-script-unit=37` dump for byte-level diff.
    @Test("_SAVE007.DAT — dump Swift u37 per-opcode script trace")
    @MainActor
    func saveSevenParityDumpU37ScriptTrace() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
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
        let traceURL = tmpDir.appendingPathComponent("swift_u37_script.txt")

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
            path: traceURL, unitPoolIndex: 37
        )
        _ = try? Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: 585,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: game,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            scriptTrace: trace
        )
        print("wrote Swift u37 script trace to \(traceURL.path)")
    }

    /// Diagnostic: dumps Swift u12 (the bullet fired by u37 at tick
    /// 581) + CYARD (structure 0) state across ticks 581..590 so we
    /// can compare the bullet-detonation window against OpenDUNE's
    /// golden. Closes the tick-586 parity drift lookup loop. Kept
    /// for future regressions in the bullet-step / structure-
    /// collision path — the "bullet delayed by 3 ticks" symptom is
    /// a quick sanity check.
    @Test("_SAVE007.DAT — dump Swift u12 bullet + CYARD around tick 586")
    @MainActor
    func saveSevenParityDumpU12BulletStateAtTick586() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let goldenURL = Self.goldenURL(named: "save007_ticks.jsonl")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }

        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
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

        let host = Scripting.Host(spiceMap: spiceMap)
        host.units = snapshot.units
        host.structures = snapshot.structures
        host.houses = snapshot.houses
        host.teams = snapshot.teams
        host.retargetImpassableDst = false
        host.deferFreeOnDeath = true
        host.landscapeAt = { packed in
            guard Int(packed) < snapshotLandscape.count else { return 0 }
            return UInt8(snapshotLandscape[Int(packed)].rawValue)
        }
        for s in snapshot.structures.slots where s.isUsed && s.type == 8 {
            host.playerHouseID = s.houseID
            break
        }
        let source = Scripting.RandomSource(lcgSeed: 0, toolsSeed: 0)
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let structureFunctions = Scripting.Functions.structureTable(host: host, source: source)
        let teamFunctions = Scripting.Functions.teamTable(host: host, source: source)
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
        let teamVM = Scripting.VM(program: teamProgram, functions: teamFunctions)
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: unitVM, structureVM: structureVM, teamVM: teamVM,
            harvestRNG: { source.toolsNext() }
        )
        scheduler.movementRNG = { _ in source.toolsNext() }
        scheduler.lcgRange = { lo, hi in source.lcgRange(lo, hi) }
        scheduler.gameSpeed = 4
        host.gameSpeed = 4
        scheduler.unitOpcodeBudget = 52
        scheduler.structureOpcodeBudget = 52
        scheduler.teamOpcodeBudget = 52
        scheduler.tickAttackHoldEnabled = false
        scheduler.tickHarvestingEnabled = false
        scheduler.perTickCadenceGatesEnabled = true
        scheduler.perUnitInterleavedTickOrder = true
        scheduler.offViewportSlowdownEnabled = true
        scheduler.viewportPackedPosition = 1297
        scheduler.seedFromSave(game)

        for t in 1...590 {
            scheduler.tick()
            if t >= 581 && t <= 590 {
                let u = host.units[12]
                let s = host.structures[0]
                print("swift t=\(t) u12 isUsed=\(u.isUsed) pos=(\(u.positionX),\(u.positionY)) currDest=(\(u.currentDestinationX),\(u.currentDestinationY)) movingSpeed=\(u.movingSpeed) speedRem=\(u.speedRemainder) hp=\(u.hitpoints)  | s0 hp=\(s.hitpoints)")
            }
        }
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

    /// Run the parity harness and assert the run matches the golden
    /// byte-for-byte through all `tickLimit` ticks. Any divergence
    /// records an Issue with the tick + field that drifted.
    @MainActor
    private func expectFullParity(
        tickLimit: Int,
        save: String,
        golden goldenName: String,
        withRealEmc: Bool = false,
        compareLandscape: Bool = false,
        compareScriptPc: Bool = false,
        compareScriptPcUnit: Int? = nil
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
        } else {
            snapshot = try Simulation.WorldSnapshot(loading: game, baseline: Map.empty())
        }

        try Simulation.ParityHarness.runAgainst(
            snapshot: snapshot,
            golden: golden,
            tickLimit: tickLimit,
            unitProgram: unitProgram,
            structureProgram: structureProgram,
            teamProgram: teamProgram,
            seedScriptsFrom: withRealEmc ? game : nil,
            spiceMap: spiceMap,
            snapshotLandscape: snapshotLandscape,
            compareLandscape: compareLandscape,
            compareScriptPc: compareScriptPc,
            compareScriptPcUnit: compareScriptPcUnit
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
