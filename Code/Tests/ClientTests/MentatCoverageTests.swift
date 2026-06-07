import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// Every unit and building has a Mentat description, including the advanced ones that the old campaign-level
/// filter hid (Palace, IX, Devastator, Sonic Tank, Ornithopter, …). Verifies each per-house `MENTAT*.ENG`
/// carries non-empty bodies for the full roster. Skips without the install.
@MainActor
struct MentatCoverageTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // Names that exist across the three Mentat files and must each be described (a spread of campaign levels,
    // including the ones the old filter hid). House-specific spellings are normalised by the lookup below.
    private let required = [
        "Construction Yard", "Refinery", "Wind Trap", "Light Factory", "Heavy Factory", "High-Tech Factory",
        "IX", "Palace", "Starport", "Rocket Turret", "Repair Facility", "Outpost", "Barracks", "Wor",
        "Light Infantry", "Trike", "Quad", "Harvester", "Carryall", "Combat Tank", "Siege Tank",
        "Rocket Tank", "MCV", "Ornithopter", "Devastator", "Deviator", "Sonic Tank", "Saboteur", "Sand Worm",
    ]

    @Test func everyUnitAndBuildingHasADescription() throws {
        guard let installURL else { print("mentat-coverage: no install — skipped"); return }

        let assets = AssetStore(installURL: installURL)
        for house in ["A", "H", "O"] {
            let topics = assets.mentatTopics(houseLetter: Character(house))
            // Index by both the literal name and a space-stripped form so "Wind Trap"/"Windtrap" and
            // "Deviator"/"Ordos Deviator" all resolve — case- and space-insensitive.
            func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
            var bodyByNorm: [String: String] = [:]
            for t in topics where !t.isHeader { bodyByNorm[norm(t.name)] = t.body }
            for name in required {
                let body = bodyByNorm[norm(name)] ?? bodyByNorm[norm("Ordos " + name)]
                #expect((body?.isEmpty == false), "MENTAT\(house): '\(name)' has no description")
            }
        }
    }
}
