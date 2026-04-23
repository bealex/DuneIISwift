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
            rngSeed: UInt32 = 0
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
                textLog: []
            )
            let source = Scripting.RandomSource(
                lcgSeed: UInt16(truncatingIfNeeded: rngSeed),
                toolsSeed: rngSeed
            )
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
                harvestRNG: { source.tools.next() }
            )

            Log.debug("parity: \(goldenTicks.count) golden ticks loaded; tickLimit=\(tickLimit)",
                      tracer: .label("parity"))

            try diff(tick: 0, golden: goldenTicks[0], host: host)

            if tickLimit >= 1 {
                for t in 1...tickLimit {
                    scheduler.tick()
                    try diff(tick: t, golden: goldenTicks[t], host: host)
                }
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
