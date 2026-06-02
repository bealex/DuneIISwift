import Foundation
import Dispatch
import Synchronization
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import DuneIISimulation

// simbench — parallelization benchmark for the Dune II tick.
//
// Builds a synthetic, deliberately busy scenario (harvesters refining, factories building tanks, CYs
// building starports, quads fighting quads) on a rock map, then times:
//   1. the sequential tick (with a per-phase breakdown),
//   2. the experimental parallel unit phase (`tickParallel`), plus an isolated, divergence-free per-tick
//      A/B of just the unit phase, and
//   3. N independent whole sims in parallel (§4a — the embarrassingly-parallel throughput win).
//
// The faithful unit pool is 102 slots partitioned by type, so a faithful sim caps at ~80 ground units.
// To probe "massive number of units" the scenario can inject cloned units past that cap — set
// DUNEII_UNIT_POOL (e.g. 8000) and pass a target unit count. Build `-c release` or the numbers are noise.
//
// Usage: simbench [groups] [ticks] [targetUnits] [shards]
enum SimBench {

    // MARK: - Config (parsed from argv)

    static let args = CommandLine.arguments
    static func arg(_ i: Int) -> Int? { args.count > i ? Int(args[i]) : nil }
    static let groups      = arg(1) ?? 14
    static let ticks       = arg(2) ?? 100
    static let targetUnits = arg(3) ?? 0
    static let cores       = ProcessInfo.processInfo.activeProcessorCount
    static let shards      = arg(4) ?? cores

    static let mapSide = 64
    static func packed(_ x: Int, _ y: Int) -> UInt16 { UInt16((y << 6) | x) }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: - Assets

    struct Assets {
        let iconMap: IconMap
        let unit: ScriptInfo
        let build: ScriptInfo
        let team: ScriptInfo?
    }

    static func resourcesDir() -> URL? {
        var repo = URL(fileURLWithPath: #filePath)          // …/Code/Apps/simbench/SimBench.swift
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() } // → repo root
        let res = repo.appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: res.appendingPathComponent("Tiles/Maps/ICON.MAP").path) { return res }
        let alt = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../Resources")
        return FileManager.default.fileExists(atPath: alt.appendingPathComponent("Tiles/Maps/ICON.MAP").path) ? alt : nil
    }

    static func loadAssets() -> Assets? {
        guard let res = resourcesDir() else { return nil }
        func data(_ rel: String) -> Data? { try? Data(contentsOf: res.appendingPathComponent(rel)) }
        guard let icon = data("Tiles/Maps/ICON.MAP").flatMap({ try? IconMap($0) }),
              let unit = data("Scripts/UNIT/UNIT.emc").flatMap({ try? Emc.Program($0) }),
              let build = data("Scripts/BUILD/BUILD.emc").flatMap({ try? Emc.Program($0) }) else { return nil }
        let team = data("Scripts/TEAM/TEAM.emc").flatMap { try? Emc.Program($0) }
        return Assets(iconMap: icon, unit: ScriptInfo(unit), build: ScriptInfo(build), team: team.map { ScriptInfo($0) })
    }

    /// Deep-copy the script bytecode buffers so a sim built from this shares *no* COW storage with any
    /// other — the test for the "cross-core refcount contention on shared `ScriptInfo`" hypothesis (§8.3).
    static func deepCopyAssets(_ a: Assets) -> Assets {
        Assets(iconMap: a.iconMap,
               unit: ScriptInfo(program: Array(a.unit.program), offsets: Array(a.unit.offsets)),
               build: ScriptInfo(program: Array(a.build.program), offsets: Array(a.build.offsets)),
               team: a.team.map { ScriptInfo(program: Array($0.program), offsets: Array($0.offsets)) })
    }

    // MARK: - Scenario construction

    /// Build the busy base scenario and return a Simulation ready to tick.
    static func buildScenario(_ a: Assets) -> Simulation {
        let cols = max(1, Int(Double(groups).squareRoot().rounded(.up)))
        let spacing = max(8, min(12, 60 / cols))

        var unitsINI = "", structuresINI = ""
        var u = 0, s = 0
        for g in 0 ..< groups {
            let col = g % cols, row = g / cols
            let ox = 2 + col * spacing, oy = 2 + row * spacing
            func P(_ dx: Int, _ dy: Int) -> UInt16 { packed(min(61, ox + dx), min(61, oy + dy)) }
            structuresINI += "ID\(s)=Harkonnen,Refinery,256,\(P(0, 0))\n"; s += 1
            structuresINI += "ID\(s)=Harkonnen,Heavy Fctry,256,\(P(4, 0))\n"; s += 1
            structuresINI += "ID\(s)=Harkonnen,Const Yard,256,\(P(0, 3))\n"; s += 1
            structuresINI += "ID\(s)=Harkonnen,Windtrap,256,\(P(4, 3))\n"; s += 1
            structuresINI += "ID\(s)=Harkonnen,Windtrap,256,\(P(6, 3))\n"; s += 1
            unitsINI += "ID\(u)=Harkonnen,Harvester,256,\(P(2, 5)),0,Guard\n"; u += 1
            unitsINI += "ID\(u)=Harkonnen,Quad,256,\(P(0, 6)),0,Guard\n"; u += 1
            unitsINI += "ID\(u)=Atreides,Quad,256,\(P(3, 6)),128,Guard\n"; u += 1
        }

        let ini = """
        [BASIC]
        MapScale=0
        [MAP]
        Seed=12345
        [Harkonnen]
        Brain=Human
        Credits=100000
        MaxUnit=999
        [Atreides]
        Brain=CPU
        Credits=100000
        MaxUnit=999
        [STRUCTURES]
        \(structuresINI)
        [UNITS]
        \(unitsINI)
        """

        var state = GameState()
        state.loadScenario(ini: Ini(text: ini), iconMap: a.iconMap)

        let rock = state.tileIDs.landscape &+ 16   // landscapeSpriteMap[16] == entirelyRock
        let spice = state.tileIDs.landscape &+ 49  // landscapeSpriteMap[49] == spice
        for i in 0 ..< state.map.count {
            state.map[i].isUnveiled = true
            if state.map[i].hasStructure { continue }
            state.map[i].groundTileID = rock
            state.mapBaseTileID[i] = rock
        }

        var sim = Simulation(state: state, scriptInfo: a.unit, structureScriptInfo: a.build,
                             teamScriptInfo: a.team, tickExplosions: false, tickAnimations: false)
        let orders = UnitOrders(scriptInfo: a.unit)

        var sf = PoolFind(type: UInt16(StructureType.heavyVehicle.rawValue))
        while let slot = sim.state.structureFind(&sf) {
            orders.apply(.build(structure: UInt16(slot), objectType: UInt16(UnitType.tank.rawValue)), in: &sim.state)
        }
        var cf = PoolFind(type: UInt16(StructureType.constructionYard.rawValue))
        while let slot = sim.state.structureFind(&cf) {
            orders.apply(.build(structure: UInt16(slot), objectType: UInt16(StructureType.starport.rawValue)), in: &sim.state)
        }

        var hf = PoolFind(type: UInt16(UnitType.harvester.rawValue))
        while let slot = sim.state.unitFind(&hf) {
            let p = sim.state.units[slot].o.position.packed
            for d in [0, 1, 64, 65, -1, -64] {
                let t = Int(p) + d
                if t >= 0 && t < sim.state.map.count && !sim.state.map[t].hasStructure {
                    sim.state.map[t].groundTileID = spice
                    sim.state.mapBaseTileID[t] = spice
                }
            }
            orders.apply(.harvest(unit: UInt16(slot), tile: p), in: &sim.state)
        }

        var quads: [Int] = []
        var qf = PoolFind(type: UInt16(UnitType.quad.rawValue))
        while let slot = sim.state.unitFind(&qf) { quads.append(slot) }
        var i = 0
        while i + 1 < quads.count {
            let a0 = quads[i], b0 = quads[i + 1]
            orders.apply(.attack(unit: UInt16(a0), tile: sim.state.units[b0].o.position.packed), in: &sim.state)
            orders.apply(.attack(unit: UInt16(b0), tile: sim.state.units[a0].o.position.packed), in: &sim.state)
            i += 2
        }

        sim.tick()   // warm scripts so clones inherit a loaded engine

        if targetUnits > sim.state.benchLiveUnitCount, let template = quads.first {
            let tmpl = sim.state.units[template]
            var slot = 102, n = sim.state.benchLiveUnitCount
            while n < targetUnits && slot < 0x3FFF {
                var clone = tmpl
                clone.o.position = Tile32.unpack(packed(1 + (slot * 7) % 60, 1 + (slot * 13) % 60))
                sim.state.benchInjectUnit(clone, at: slot)
                slot += 1; n += 1
            }
        }
        return sim
    }

    // MARK: - Timing helpers

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    static func timed(_ body: () -> Void) -> Duration {
        let c = ContinuousClock(); let t0 = c.now; body(); return t0.duration(to: c.now)
    }
    static func phaseLine(_ label: String, _ t: PhaseTimings) -> String {
        let tot = ms(t.total)
        func pct(_ d: Duration) -> String { String(format: "%.1f%%", tot > 0 ? ms(d) / tot * 100 : 0) }
        return String(format: "  %@: %.2f ms total, %.4f ms/tick, %.0f ticks/s\n", label,
                      tot, tot / Double(max(1, t.ticks)), Double(t.ticks) / max(0.0001, tot / 1000))
            + "       team \(pct(t.team)) | unit \(pct(t.unit)) | structure \(pct(t.structure)) | house \(pct(t.house)) | other \(pct(t.other))"
    }

    // MARK: - Run

    static func run() {
        guard let assets = loadAssets() else {
            FileHandle.standardError.write(Data("simbench: could not load Resources/ (need ICON.MAP + Scripts).\n".utf8))
            exit(1)
        }

        let probe = buildScenario(assets)
        print("""
        ======================================================================
          simbench — Dune II tick parallelization
        ======================================================================
          cores: \(cores)   shards: \(shards)   ticks/run: \(ticks)
          scenario: \(groups) groups → \(probe.state.benchLiveUnitCount) live units, \(probe.state.benchLiveStructureCount) structures
          unit pool cap (DUNEII_UNIT_POOL): \(Pool.unitIndexMax)
          build: \(isDebugBuild ? "DEBUG — NUMBERS NOT MEANINGFUL, use -c release" : "release")
        ----------------------------------------------------------------------
        """)

        // [0] parallel sanity: pure compute, no shared state. Proves the harness/machine parallelizes, so a
        //     sim slowdown below is intrinsic (shared-refcount contention / per-tick allocation), not the test.
        do {
            let n = cores
            let sink = Mutex<Double>(0)   // observed result ⇒ the compiler can't eliminate the loop
            let work: @Sendable (Int) -> Double = { seed in
                var x = 0.0; for i in 1 ..< 8_000_000 { x += (Double(i) + Double(seed)).squareRoot() }; return x
            }
            let seq = timed { for k in 0 ..< n { let r = work(k); sink.withLock { $0 += r } } }
            let par = timed { DispatchQueue.concurrentPerform(iterations: n) { k in let r = work(k); sink.withLock { $0 += r } } }
            print(String(format: "[0] parallel sanity (pure compute, %d tasks): seq %.1f ms | par %.1f ms | %.1f×  (checksum %.0f)\n",
                         n, ms(seq), ms(par), ms(seq) / max(0.0001, ms(par)), sink.withLock { $0 }))
        }

        // [1] sequential full run, per-phase.
        do {
            var sim = buildScenario(assets)
            var t = PhaseTimings()
            for _ in 0 ..< ticks { sim.tickTimed(parallelUnits: false, shardCount: shards, into: &t) }
            print("[1] sequential tick")
            print(phaseLine("seq", t))
        }

        // [2] parallel-unit full run (NON-GOLDEN: diverges; cross-shard effects dropped).
        do {
            var sim = buildScenario(assets)
            var t = PhaseTimings()
            for _ in 0 ..< ticks { sim.tickTimed(parallelUnits: true, shardCount: shards, into: &t) }
            print("\n[2] parallel unit phase (non-golden)")
            print(phaseLine("par", t))
        }

        // [3] isolated, divergence-free unit-phase A/B on identical per-tick inputs.
        do {
            var sim = buildScenario(assets)
            var seqUnit = Duration.zero, parUnit = Duration.zero
            for _ in 0 ..< ticks {
                let snap = sim
                var s1 = snap; seqUnit += timed { s1.gameLoopUnitSequential() }
                var s2 = snap; parUnit += timed { s2.gameLoopUnitParallel(shardCount: shards) }
                sim.tick()
            }
            let speedup = ms(seqUnit) / max(0.0001, ms(parUnit))
            print("\n[3] unit-phase A/B on identical inputs (fair, divergence-free)")
            print(String(format: "  sequential: %.2f ms | parallel: %.2f ms | %.2f× %@",
                         ms(seqUnit), ms(parUnit), speedup, speedup >= 1 ? "FASTER" : "SLOWER"))
        }

        // [4] §4a — N independent whole sims in parallel (fully correct). Construction excluded from timing.
        do {
            let n = cores
            let sims = (0 ..< n).map { _ in buildScenario(assets) }
            let seqTime = timed {
                for i in 0 ..< n { var sim = sims[i]; for _ in 0 ..< ticks { sim.tick() } }
            }
            let parTime = timed {
                DispatchQueue.concurrentPerform(iterations: n) { i in
                    var sim = sims[i]; for _ in 0 ..< ticks { sim.tick() }
                }
            }
            let speedup = ms(seqTime) / max(0.0001, ms(parTime))
            print("\n[4] \(n) independent sims, SHARED script data (§4a, fully correct)")
            print(String(format: "  sequential: %.2f ms | parallel: %.2f ms | %.2f× speedup", ms(seqTime), ms(parTime), speedup))
        }

        // [5] §4a again, but each worker gets its OWN deep-copied ScriptInfo (no shared COW buffer). If this
        //     parallelizes where [4] didn't, the cross-core refcount contention on shared `ScriptInfo` was
        //     the cause — and per-worker data is the fix. Construction is excluded from timing (pre-built).
        do {
            let n = cores
            let sims = (0 ..< n).map { _ in buildScenario(deepCopyAssets(assets)) }
            let seqTime = timed {
                for i in 0 ..< n { var sim = sims[i]; for _ in 0 ..< ticks { sim.tick() } }
            }
            let parTime = timed {
                DispatchQueue.concurrentPerform(iterations: n) { i in
                    var sim = sims[i]; for _ in 0 ..< ticks { sim.tick() }
                }
            }
            let speedup = ms(seqTime) / max(0.0001, ms(parTime))
            print("\n[5] \(n) independent sims, PER-WORKER de-shared script data (§4a)")
            print(String(format: "  sequential: %.2f ms | parallel: %.2f ms | %.2f× speedup", ms(seqTime), ms(parTime), speedup))
        }

        // [6] Zero shared Swift objects between workers: each builds AND ticks its own sim (de-shared assets).
        //     The only thing still shared is the global stat tables (UnitInfo/…) + the allocator. If this
        //     still doesn't scale, the bottleneck is memory bandwidth / allocation, not any sharing we control.
        do {
            let n = cores
            let seqTime = timed {
                for _ in 0 ..< n { var sim = buildScenario(deepCopyAssets(assets)); for _ in 0 ..< ticks { sim.tick() } }
            }
            let parTime = timed {
                DispatchQueue.concurrentPerform(iterations: n) { _ in
                    var sim = buildScenario(deepCopyAssets(assets)); for _ in 0 ..< ticks { sim.tick() }
                }
            }
            let speedup = ms(seqTime) / max(0.0001, ms(parTime))
            print("\n[6] \(n) independent sims, BUILD+TICK per worker, nothing shared but global tables/allocator")
            print(String(format: "  sequential: %.2f ms | parallel: %.2f ms | %.2f× speedup", ms(seqTime), ms(parTime), speedup))
        }

        print("======================================================================")
    }
}
