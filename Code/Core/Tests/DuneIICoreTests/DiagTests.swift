import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Diagnostics")
struct DiagTests {
    @Test("SAVE007 trace u36 across ticks")
    @MainActor
    func traceU36() throws {
        guard let root = TestInstall.locate() else { return }
        let saveURL = root.appendingPathComponent("_SAVE007.DAT")
        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let unitProgram = (try assets.loadEmc(named: "UNIT.EMC")) ?? .empty
        let structureProgram = (try assets.loadEmc(named: "BUILD.EMC")) ?? .empty
        let teamProgram = (try assets.loadEmc(named: "TEAM.EMC")) ?? .empty
        let resolver = assets.tileResolver
        let baseline = Map.Generator.generate(seed: game.info.scenario.mapSeed, resolver: resolver)
        let snapshot = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        let snapshotLandscape = snapshot.tiles.map { tile in
            resolver.landscapeType(
                groundTileID: tile.groundTileID,
                overlayTileID: tile.overlayTileID,
                hasStructure: tile.hasStructure
            )
        }
        let spiceMap = Simulation.SpiceMap { i in snapshotLandscape[i] }
        let landscapeAt: (UInt16) -> UInt8 = { packed in
            UInt8(snapshotLandscape[Int(packed)].rawValue)
        }

        let host = Scripting.Host(
            units: snapshot.units,
            structures: snapshot.structures,
            explosions: Simulation.ExplosionPool(),
            teams: snapshot.teams,
            houses: snapshot.houses,
            landscapeAt: landscapeAt,
            spiceMap: spiceMap
        )
        host.gameSpeed = 4
        let source = Scripting.RandomSource(lcgSeed: 0, toolsSeed: 0)
        let unitFns = Scripting.Functions.unitTable(host: host, source: source)
        let structFns = Scripting.Functions.structureTable(host: host, source: source)
        let teamFns = Scripting.Functions.teamTable(host: host, source: source)
        let uVM = Scripting.VM(program: unitProgram, functions: unitFns)
        let sVM = Scripting.VM(program: structureProgram, functions: structFns)
        let tVM = Scripting.VM(program: teamProgram, functions: teamFns)
        var scheduler = Simulation.Scheduler(host: host, unitVM: uVM, structureVM: sVM, teamVM: tVM, harvestRNG: { source.toolsNext() })
        scheduler.gameSpeed = 4
        scheduler.viewportPackedPosition = 1297
        scheduler.unitOpcodeBudget = 52
        scheduler.structureOpcodeBudget = 52
        scheduler.teamOpcodeBudget = 52
        scheduler.tickAttackHoldEnabled = false
        scheduler.tickHarvestingEnabled = false
        scheduler.offViewportSlowdownEnabled = true
        scheduler.perTickCadenceGatesEnabled = true
        scheduler.seedFromSave(game)

        func dumpU36(_ t: Int) {
            let s = host.units.slots[36]
            print("t\(t): u36 pos=(\(s.positionX),\(s.positionY)) curD=(\(s.currentDestinationX),\(s.currentDestinationY)) spd=\(s.speed) spt=\(s.speedPerTick) rem=\(s.speedRemainder) oc=\(s.orientationCurrent) r0=\(s.route[0])")
        }
        dumpU36(0)
        for t in 1...26 {
            scheduler.tick()
            if t <= 6 || t == 10 || t == 15 || t == 20 || t >= 22 {
                dumpU36(t)
            }
        }
    }
}
