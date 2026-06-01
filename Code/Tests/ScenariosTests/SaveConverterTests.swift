import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld

/// Cross-engine check of the original-save converter: the OpenDUNE oracle saved a small scenario
/// (`--parity-save` → `convert-save.sav`) and dumped the same tick-0 state (`convert-save-golden.jsonl`). The
/// Swift `SaveConverter` reads that `.SAV` and must reproduce the oracle's houses / structures / on-map units.
@Suite("Original-save converter vs OpenDUNE")
struct SaveConverterTests {
    struct Frame: Decodable { let houses: [HouseG]?; let structures: [StructureG]?; let units: [UnitG]? }
    struct HouseG: Decodable, Equatable { let index: UInt16; let credits: UInt16; let creditsStorage: UInt16
        let powerProduction: UInt16; let powerUsage: UInt16; let unitCount: UInt16 }
    struct StructureG: Decodable, Equatable { let index: UInt16; let type: UInt8; let houseID: UInt8
        let hitpoints: UInt16; let state: Int16 }
    struct UnitG: Decodable, Equatable { let index: UInt16; let type: UInt8; let houseID: UInt8
        let packed: UInt16; let hp: UInt16; let actionID: UInt8 }

    @Test("converts a real OpenDUNE .SAV — houses, structures + on-map units match the oracle")
    func convertMatchesOracle() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let fix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let sav = try? Data(contentsOf: fix.appendingPathComponent("convert-save.sav")),
              let goldenText = try? String(contentsOf: fix.appendingPathComponent("convert-save-golden.jsonl"), encoding: .utf8)
        else { return }
        let oracle = try JSONDecoder().decode(Frame.self, from: Data(goldenText.split(separator: "\n")[0].utf8))

        let state = try SaveConverter.convert(sav, iconMap: try IconMap(iconData))

        // Houses.
        let houses = state.houses.indices.filter { state.houses[$0].flags.contains(.used) }.map {
            HouseG(index: UInt16(state.houses[$0].index), credits: state.houses[$0].credits,
                   creditsStorage: state.houses[$0].creditsStorage, powerProduction: state.houses[$0].powerProduction,
                   powerUsage: state.houses[$0].powerUsage, unitCount: state.houses[$0].unitCount)
        }.sorted { $0.index < $1.index }
        #expect(houses == (oracle.houses ?? []).sorted { $0.index < $1.index })

        // Structures.
        let structs = state.structures.indices.filter { state.structures[$0].o.flags.contains(.used) }.map {
            StructureG(index: state.structures[$0].o.index, type: state.structures[$0].o.type,
                       houseID: state.structures[$0].o.houseID, hitpoints: state.structures[$0].o.hitpoints,
                       state: state.structures[$0].state.rawValue)
        }.sorted { $0.index < $1.index }
        #expect(structs == (oracle.structures ?? []).sorted { $0.index < $1.index })

        // On-map units (the oracle's Unit_Find skips in-transport units, so we do too).
        let units = state.units.indices
            .filter { state.units[$0].o.flags.contains(.used) && !state.units[$0].o.flags.contains(.isNotOnMap) }
            .map {
                UnitG(index: state.units[$0].o.index, type: state.units[$0].o.type, houseID: state.units[$0].o.houseID,
                      packed: state.units[$0].o.position.packed, hp: state.units[$0].o.hitpoints,
                      actionID: state.units[$0].actionID)
            }.sorted { $0.index < $1.index }
        #expect(units == (oracle.units ?? []).sorted { $0.index < $1.index })
    }
}
