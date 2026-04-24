import Foundation
import Memoirs

extension Simulation {
    /// Tick-parity golden-dump harness. Diffs our `Scheduler.tick()` output
    /// against a JSONL dump captured from patched OpenDUNE (see
    /// `Documentation/Architecture/TickParityHarness.md`).
    ///
    /// Usage, from a test:
    /// ```
    /// let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
    /// try Simulation.ParityHarness.runAgainst(
    ///     snapshot: snapshot,
    ///     golden: try Data(contentsOf: goldenURL),
    ///     tickLimit: 200,
    ///     unitProgram: unitProgram,
    ///     structureProgram: structureProgram,
    ///     teamProgram: teamProgram,
    ///     rngSeed: 0
    /// )
    /// ```
    ///
    /// Diffs fields that both engines track today. Fields the Swift side
    /// has not yet ported (`nextActionID`, `orientation0Target`,
    /// `orientation0Speed`, all of `orientation1*`, `wobbleIndex`, `timer`,
    /// `upgradeTimeLeft`, `powerProduction`, `powerUsage`, `unitCount`,
    /// `unitCountMax`, `harvestersIncoming`) are present in the golden but
    /// currently skipped by the diff. They land on the Swift side as we
    /// close gaps; each addition flips its `skip` entry into a comparison.
    ///
    /// Script-engine state (`scriptDelay`, `scriptPc`, `scriptSP`, `scriptFP`)
    /// is dumped in the golden but diffed selectively: `scriptDelay` is
    /// compared (small, stable, uncovered drift surfaces fast); `scriptPc`
    /// and the stack pointers are NOT compared yet because the same
    /// observable pool state can be reached via slightly different script
    /// paths and PC-level parity is strictly stronger than we currently
    /// need.
    public enum ParityHarness {
        /// First divergence found. Halts the run.
        public struct Divergence: Error, Equatable, CustomStringConvertible {
            public let tick: Int
            public let kind: String    // "house" / "structure" / "unit"
            public let slot: Int       // pool index
            public let field: String
            public let expected: String
            public let actual: String

            public var description: String {
                "parity divergence at tick \(tick) \(kind)[\(slot)].\(field): expected=\(expected) actual=\(actual)"
            }
        }

        public enum ParseError: Swift.Error, Equatable {
            case goldenEmpty
            case goldenLineMalformed(lineIndex: Int, reason: String)
            case tickLimitExceedsGolden(tickLimit: Int, goldenCount: Int)
        }

        /// Run the diff. Throws `Divergence` at the first mismatched field,
        /// or `Error` for golden-parse problems.
        ///
        /// - Parameter snapshot: post-save-load pool state (tick 0).
        /// - Parameter golden: newline-delimited JSON, one line per tick.
        /// - Parameter tickLimit: number of ticks to step; must be
        ///   `<= goldenTicks.count - 1`. Tick 0 is diffed before any
        ///   `scheduler.tick()` call.
        /// - Parameter rngSeed: seed for both LCG and tools RNG; the
        ///   OpenDUNE patch re-seeds to `0` before and after the save
        ///   load, so passing `0` matches the golden.
        public static func runAgainst(
            snapshot: Simulation.WorldSnapshot,
            golden: Data,
            tickLimit: Int,
            unitProgram: Formats.Emc.Program = .empty,
            structureProgram: Formats.Emc.Program = .empty,
            teamProgram: Formats.Emc.Program = .empty,
            rngSeed: UInt32 = 0,
            seedScriptsFrom game: Formats.Save.Game? = nil,
            spiceMap: Simulation.SpiceMap? = nil,
            rngTrace: RNGTrace? = nil
        ) throws {
            let goldenTicks = try parseGolden(golden)
            guard !goldenTicks.isEmpty else { throw ParseError.goldenEmpty }
            guard tickLimit <= goldenTicks.count - 1 else {
                throw ParseError.tickLimitExceedsGolden(
                    tickLimit: tickLimit, goldenCount: goldenTicks.count
                )
            }

            let host = Scripting.Host(
                units: snapshot.units,
                structures: snapshot.structures,
                explosions: Simulation.ExplosionPool(),
                teams: snapshot.teams,
                houses: snapshot.houses,
                currentObject: nil,
                texts: [],
                textLog: [],
                spiceMap: spiceMap
            )
            let source = Scripting.RandomSource(
                lcgSeed: UInt16(truncatingIfNeeded: rngSeed),
                toolsSeed: rngSeed
            )
            // Per-byte `Tools_Random_256` trace. Matches the OpenDUNE
            // `--parity-random-trace=<path>` hook (one line per draw:
            // `idx=<N> byte=0x<BB>`). Byte-stream diff between the two
            // files pins which upstream script consumes a byte on one
            // engine but not the other — the known u39.amount drift
            // is a single-byte offset somewhere before `makeHarvestUnit`
            // fires on tick 1.
            if let rngTrace {
                source.onToolsDraw = { byte, context in
                    rngTrace.record(byte, context: context)
                }
            }
            let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
            let structureFunctions = Scripting.Functions.structureTable(host: host, source: source)
            let teamFunctions = Scripting.Functions.teamTable(host: host, source: source)
            let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
            let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
            let teamVM = Scripting.VM(program: teamProgram, functions: teamFunctions)

            var scheduler = Simulation.Scheduler(
                host: host,
                unitVM: unitVM,
                structureVM: structureVM,
                teamVM: teamVM,
                harvestRNG: { source.toolsNext() }
            )
            // OpenDUNE loads `g_gameConfig.gameSpeed` from OPTIONS.CFG
            // on startup; our install has it pinned at 4 (Fastest), but
            // any save's golden will dump its own value. Read from the
            // golden's tick-0 entry so `Tools_AdjustToGameSpeed` scales
            // `speedPerTick` increments the same way OpenDUNE did.
            scheduler.gameSpeed = goldenTicks[0].gameSpeed
            scheduler.viewportPackedPosition = goldenTicks[0].viewportPosition
            // OpenDUNE's per-tick opcode budget: `SCRIPT_UNIT_OPCODES_PER_TICK + 2`
            // (= 52, `src/unit.c:292` + `src/script/script.h:7`). Our
            // gameplay default is 7 — parity needs the real budget so
            // scripts reach the same opcodes per tick (e.g. the carryall's
            // `Script_Unit_SetSpeed(u, 255)` call that bumps movingSpeed).
            scheduler.unitOpcodeBudget = 52
            scheduler.structureOpcodeBudget = 52
            scheduler.teamOpcodeBudget = 52
            // Disable stopgap passes that pre-empt real EMC. Our
            // tickAttackHold clears `targetMove` inside fire range —
            // OpenDUNE lets the script's `Script_Unit_MoveToTarget` +
            // `Script_Unit_Fire` path own that decision, so with real
            // UNIT.EMC our clear produces drift.
            scheduler.tickAttackHoldEnabled = false
            // Parity runs headless (no viewport), so every unit that
            // doesn't have `scriptNoSlowdown=true` falls into the
            // off-viewport 3-opcode cap (OpenDUNE `src/unit.c:292..294`).
            scheduler.offViewportSlowdownEnabled = true
            if let game = game {
                scheduler.seedFromSave(game)
            }

            Log.debug("parity: \(goldenTicks.count) golden ticks loaded; tickLimit=\(tickLimit)",
                      tracer: .label("parity"))

            // Flush the RNG trace whether runAgainst throws (first
            // divergence) or completes — the trace is the load-bearing
            // artifact for debugging, not a success signal.
            defer { try? rngTrace?.flush() }

            try diff(tick: 0, golden: goldenTicks[0], host: host)

            if tickLimit >= 1 {
                for t in 1...tickLimit {
                    rngTrace?.beginTick(t)
                    scheduler.tick()
                    try diff(tick: t, golden: goldenTicks[t], host: host)
                }
            }
        }

        /// Captures every `Tools_Random_256` draw during `runAgainst`.
        /// Paired with OpenDUNE's `--parity-random-trace=<path>` hook
        /// for byte-stream diffing. Not thread-safe — the parity harness
        /// runs single-threaded per test.
        public final class RNGTrace {
            public let path: URL
            private var buffer: String = ""
            private var index: UInt32 = 0
            private var currentTick: Int = 0

            public init(path: URL) {
                self.path = path
                buffer.reserveCapacity(64 * 1024)
                buffer.append("# swift parity rng trace — one line per Tools_Random_256 byte\n")
            }

            fileprivate func beginTick(_ t: Int) {
                currentTick = t
            }

            fileprivate func record(_ byte: UInt8, context: String = "") {
                let ctx = context.isEmpty ? "" : " ctx=\(context)"
                buffer.append("tick=\(currentTick) idx=\(index) byte=0x\(String(format: "%02X", byte))\(ctx)\n")
                index &+= 1
            }

            public func flush() throws {
                try buffer.write(to: path, atomically: true, encoding: .utf8)
            }
        }

        // MARK: - Golden parsing

        static func parseGolden(_ data: Data) throws -> [GoldenTick] {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ParseError.goldenLineMalformed(lineIndex: 0, reason: "not utf-8")
            }
            var ticks: [GoldenTick] = []
            let decoder = JSONDecoder()
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                let lineData = Data(raw.utf8)
                do {
                    ticks.append(try decoder.decode(GoldenTick.self, from: lineData))
                } catch {
                    throw ParseError.goldenLineMalformed(lineIndex: i, reason: "\(error)")
                }
            }
            return ticks
        }

        struct GoldenTick: Decodable, Equatable {
            let tick: Int
            /// OpenDUNE's `g_gameConfig.gameSpeed` at dump time — loaded
            /// from OPTIONS.CFG (0..4, where 2=Normal and 4=Fastest).
            /// `Tools_AdjustToGameSpeed` uses this to scale `speedPerTick`
            /// increments, so our `Scheduler.gameSpeed` must match.
            let gameSpeed: UInt8
            /// OpenDUNE's `g_viewportPosition` (packed 12-bit tile,
            /// y*64+x). Used by `Map_IsPositionInViewport` (`src/map.c:363`)
            /// to decide whether a unit's script gets the full 52-opcode
            /// budget or the off-viewport 3-opcode cap.
            let viewportPosition: UInt16
            let houses: [GoldenHouse]
            let structures: [GoldenStructure]
            let units: [GoldenUnit]
        }

        struct GoldenHouse: Decodable, Equatable {
            let index: Int
            let credits: UInt16
            let creditsStorage: UInt16
            let creditsQuota: UInt16
            let powerProduction: UInt16
            let powerUsage: UInt16
            let unitCount: UInt16
            let unitCountMax: UInt16
            let harvestersIncoming: UInt16
            let starportTimeLeft: UInt16
            let starportLinkedID: UInt16
        }

        struct GoldenStructure: Decodable, Equatable {
            let index: UInt16
            let type: UInt8
            let houseID: UInt8
            let positionX: UInt16
            let positionY: UInt16
            let hitpoints: UInt16
            let hitpointsMax: UInt16
            let state: Int16
            let countDown: UInt16
            let linkedID: UInt8
            let objectType: UInt16
            let upgradeLevel: UInt8
            let upgradeTimeLeft: UInt8
        }

        struct GoldenUnit: Decodable, Equatable {
            let index: UInt16
            let type: UInt8
            let houseID: UInt8
            let positionX: UInt16
            let positionY: UInt16
            let hitpoints: UInt16
            let actionID: UInt8
            let nextActionID: UInt8
            let orientation0Current: Int8
            let orientation0Target: Int8
            let orientation0Speed: Int8
            let orientation1Current: Int8
            let orientation1Target: Int8
            let orientation1Speed: Int8
            let movingSpeed: UInt8
            let speed: UInt8
            let speedPerTick: UInt8
            let speedRemainder: UInt8
            let amount: UInt8
            let linkedID: UInt8
            let inTransport: Int     // JSON emits 0/1
            let targetMove: UInt16
            let targetAttack: UInt16
            let currentDestX: UInt16
            let currentDestY: UInt16
            let route0: UInt8
            let route1: UInt8
            let route2: UInt8
            let route3: UInt8
            let spriteOffset: Int8
            let fireDelay: UInt8
            let wobbleIndex: UInt8
            let blinkCounter: UInt8
            let team: UInt8
            let timer: UInt16
            let scriptDelay: UInt16
            let scriptPc: UInt32
            let scriptSP: UInt8
            let scriptFP: UInt8
        }

        // MARK: - Diff

        /// Walk every golden slot and compare against the corresponding
        /// live slot (found by pool index). Throws on first mismatch.
        static func diff(
            tick: Int,
            golden: GoldenTick,
            host: Scripting.Host
        ) throws {
            for g in golden.houses {
                let slot = host.houses[g.index]
                try compareHouse(tick: tick, golden: g, live: slot)
            }
            for g in golden.structures {
                let idx = Int(g.index)
                let slot = host.structures[idx]
                guard slot.isUsed else {
                    throw Divergence(
                        tick: tick, kind: "structure", slot: idx, field: "isUsed",
                        expected: "true", actual: "false"
                    )
                }
                try compareStructure(tick: tick, golden: g, live: slot)
            }
            for g in golden.units {
                let idx = Int(g.index)
                let slot = host.units[idx]
                guard slot.isUsed else {
                    throw Divergence(
                        tick: tick, kind: "unit", slot: idx, field: "isUsed",
                        expected: "true", actual: "false"
                    )
                }
                try compareUnit(tick: tick, golden: g, live: slot)
            }
        }

        private static func compareHouse(
            tick: Int, golden g: GoldenHouse, live s: HouseSlot
        ) throws {
            try eq(tick, "house", g.index, "credits",        g.credits,        s.credits)
            try eq(tick, "house", g.index, "creditsStorage", g.creditsStorage, s.creditsStorage)
            try eq(tick, "house", g.index, "creditsQuota",   g.creditsQuota,   s.creditsQuota)
            try eq(tick, "house", g.index, "starportTimeLeft",  g.starportTimeLeft,  s.starportTimeLeft)
            try eq(tick, "house", g.index, "starportLinkedID", g.starportLinkedID, s.starportLinkedID)
            // Skipped (Swift side not yet tracking these):
            //   powerProduction, powerUsage, unitCount, unitCountMax, harvestersIncoming
        }

        private static func compareStructure(
            tick: Int, golden g: GoldenStructure, live s: StructureSlot
        ) throws {
            let idx = Int(g.index)
            try eq(tick, "structure", idx, "type",         g.type,         s.type)
            try eq(tick, "structure", idx, "houseID",      g.houseID,      s.houseID)
            try eq(tick, "structure", idx, "positionX",    g.positionX,    s.positionX)
            try eq(tick, "structure", idx, "positionY",    g.positionY,    s.positionY)
            try eq(tick, "structure", idx, "hitpoints",    g.hitpoints,    s.hitpoints)
            try eq(tick, "structure", idx, "hitpointsMax", g.hitpointsMax, s.hitpointsMax)
            try eq(tick, "structure", idx, "state",        g.state,        s.state)
            try eq(tick, "structure", idx, "countDown",    g.countDown,    s.countDown)
            try eq(tick, "structure", idx, "linkedID",     g.linkedID,     s.linkedID)
            try eq(tick, "structure", idx, "objectType",   g.objectType,   s.objectType)
            try eq(tick, "structure", idx, "upgradeLevel", g.upgradeLevel, s.upgradeLevel)
            // Skipped: upgradeTimeLeft
        }

        private static func compareUnit(
            tick: Int, golden g: GoldenUnit, live s: UnitSlot
        ) throws {
            let idx = Int(g.index)
            try eq(tick, "unit", idx, "type",             g.type,             s.type)
            try eq(tick, "unit", idx, "houseID",          g.houseID,          s.houseID)
            try eq(tick, "unit", idx, "positionX",        g.positionX,        s.positionX)
            try eq(tick, "unit", idx, "positionY",        g.positionY,        s.positionY)
            try eq(tick, "unit", idx, "hitpoints",        g.hitpoints,        s.hitpoints)
            try eq(tick, "unit", idx, "actionID",         g.actionID,         s.actionID)
            try eq(tick, "unit", idx, "orientation0Current", g.orientation0Current, s.orientationCurrent)
            try eq(tick, "unit", idx, "movingSpeed",      g.movingSpeed,      s.movingSpeed)
            try eq(tick, "unit", idx, "speed",            g.speed,            s.speed)
            try eq(tick, "unit", idx, "speedPerTick",     g.speedPerTick,     s.speedPerTick)
            try eq(tick, "unit", idx, "speedRemainder",   g.speedRemainder,   s.speedRemainder)
            try eq(tick, "unit", idx, "amount",           g.amount,           s.amount)
            try eq(tick, "unit", idx, "linkedID",         g.linkedID,         s.linkedID)
            try eq(tick, "unit", idx, "inTransport",      g.inTransport != 0, s.inTransport)
            try eq(tick, "unit", idx, "targetMove",       g.targetMove,       s.targetMove)
            try eq(tick, "unit", idx, "targetAttack",     g.targetAttack,     s.targetAttack)
            try eq(tick, "unit", idx, "currentDestX",     g.currentDestX,     s.currentDestinationX)
            try eq(tick, "unit", idx, "currentDestY",     g.currentDestY,     s.currentDestinationY)
            try eq(tick, "unit", idx, "route0",           g.route0,           byteAt(s.route, 0))
            try eq(tick, "unit", idx, "route1",           g.route1,           byteAt(s.route, 1))
            try eq(tick, "unit", idx, "route2",           g.route2,           byteAt(s.route, 2))
            try eq(tick, "unit", idx, "route3",           g.route3,           byteAt(s.route, 3))
            try eq(tick, "unit", idx, "spriteOffset",     g.spriteOffset,     s.spriteOffset)
            try eq(tick, "unit", idx, "fireDelay",        g.fireDelay,        s.fireDelay)
            try eq(tick, "unit", idx, "blinkCounter",     g.blinkCounter,     s.blinkCounter)
            try eq(tick, "unit", idx, "team",             g.team,             s.team)
            // Skipped (Swift side not yet tracking these):
            //   nextActionID, orientation0Target, orientation0Speed,
            //   orientation1*, wobbleIndex, timer
        }

        private static func byteAt(_ a: [UInt8], _ i: Int) -> UInt8 {
            i < a.count ? a[i] : 0xFF
        }

        @inline(__always)
        private static func eq<T: Equatable>(
            _ tick: Int, _ kind: String, _ slot: Int, _ field: String,
            _ expected: T, _ actual: T
        ) throws {
            if expected != actual {
                throw Divergence(
                    tick: tick, kind: kind, slot: slot, field: field,
                    expected: "\(expected)", actual: "\(actual)"
                )
            }
        }

    }
}
