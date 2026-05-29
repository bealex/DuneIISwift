import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// The structure Animation system end-to-end: load a scenario (which stamps buildings + starts their
/// animations), tick the loop, and verify a building's ground tiles actually cycle over time.
@Suite("Structure animation")
struct AnimationTests {
    @Test("a placed building's tiles animate as the loop ticks")
    func buildingAnimates() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = try Ini(Data(contentsOf: repo.appendingPathComponent("Resources/Scenarios/SCENA001.INI")))

        var sim = Simulation()
        sim.state.loadScenario(ini: ini, iconMap: iconMap)

        // The construction yard (animationIndex 22 → cycles ground states 2↔3).
        let structure = try #require(sim.state.structures.first {
            $0.o.flags.contains(.used) && $0.o.type == UInt8(StructureType.constructionYard.rawValue)
        })
        let packed = Int(structure.o.position.packed)
        #expect(sim.state.map[packed].hasStructure)

        var seen = Set<UInt16>([sim.state.map[packed].groundTileID])
        for _ in 0 ..< 300 {
            sim.tick()
            seen.insert(sim.state.map[packed].groundTileID)
        }
        #expect(seen.count > 1, "the building's tile should cycle through animation states")
    }
}
