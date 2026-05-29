import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// Loads every committed scenario `.INI` and checks, for all of them: each placed unit/structure sits
/// at the position declared in the INI, and every unit's body/turret sprite indices resolve (turret
/// presence matching `turretSpriteID`). The INI is the canonical source for positions (OpenDUNE reads
/// the same fields), and the sprite indices come from the `viewport.c`-faithful `UnitSprites`.
@Suite("All scenarios — positions + sprite indices")
struct AllScenariosTests {
    @Test("every scenario: object positions match the INI, unit sprites resolve")
    func allScenarios() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let dir = repo.appendingPathComponent("Resources/Scenarios")

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.uppercased().hasPrefix("SCEN") && $0.pathExtension.uppercased() == "INI" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count > 20)   // ~22 campaign scenarios

        var totalUnits = 0, totalStructures = 0
        for file in files {
            let name = file.lastPathComponent
            let ini = Ini(try Data(contentsOf: file))
            var state = GameState()
            state.loadScenario(ini: ini, iconMap: iconMap)

            // Expected positions straight from the INI.
            var unitPositions = Set<UInt16>()
            for key in ini.keys(section: "UNITS") {
                if let packed = field(ini.string(section: "UNITS", key: key), 3) { unitPositions.insert(packed) }
            }
            var structurePositions = Set<UInt16>()
            for key in ini.keys(section: "STRUCTURES") {
                if key.uppercased().hasPrefix("GEN") {
                    if let packed = UInt16(key.dropFirst(3)) { structurePositions.insert(packed) }
                } else if let packed = field(ini.string(section: "STRUCTURES", key: key), 3) {
                    structurePositions.insert(packed)
                }
            }

            for u in state.units where u.o.flags.contains(.used) {
                #expect(unitPositions.contains(u.o.position.packed), "\(name): unit at \(u.o.position.packed) not in INI")
                let type = try #require(UnitType(rawValue: Int(u.o.type)))
                let sprites = try #require(UnitSprites.info(for: u), "\(name): unit \(type) sprite unresolved")
                let expectsTurret = UnitInfo[type].turretSpriteID != 0xFFFF
                #expect((sprites.turret != nil) == expectsTurret, "\(name): \(type) turret presence")
                #expect(sprites.body.spriteIndex >= Int(UnitInfo[type].groundSpriteID))
                totalUnits += 1
            }
            for s in state.structures where s.o.flags.contains(.used) {
                #expect(structurePositions.contains(s.o.position.packed), "\(name): structure at \(s.o.position.packed) not in INI")
                totalStructures += 1
            }
        }
        #expect(totalUnits > 0)
        #expect(totalStructures > 0)
    }

    /// The `index`-th comma-separated field of an INI value, parsed as a packed position.
    private func field(_ value: String?, _ index: Int) -> UInt16? {
        let parts = (value ?? "").split(separator: ",", omittingEmptySubsequences: false)
        guard index < parts.count, let n = Int(parts[index].trimmingCharacters(in: .whitespaces)) else { return nil }
        return UInt16(clamping: n)
    }
}
