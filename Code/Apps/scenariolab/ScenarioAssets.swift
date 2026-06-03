import DuneIIFormats
import DuneIIScenarios
import DuneIISimulation
import Foundation

/// Loads the install's assets the scenario lab needs — palette, the `ICON.ICN` tile set, the unit SHPs,
/// and the unit-category EMC program (`UNIT.EMC`) — and builds a `ScenarioBuilder`. Mirrors `mapview`'s
/// asset store.
@MainActor
@Observable
final class ScenarioAssets {
    private(set) var error: String?
    private(set) var palette = ScenarioAssets.grayscale
    private(set) var tileSet: Icn.TileSet?
    private(set) var builder: ScenarioBuilder?

    private var archives: [Pak.Archive] = []
    private var shpCache: [String: Shp.FrameSet] = [:]

    static let grayscale: Palette = {
        var colors: [Palette.Color] = []
        for i in 0 ..< 256 { let v = UInt8(i / 4); colors.append(Palette.Color(red: v, green: v, blue: v)) }
        return Palette(colors: colors)
    }()

    init(installURL: URL) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(at: installURL, includingPropertiesForKeys: nil)
        else {
            error = "Cannot read install directory: \(installURL.path)"
            return
        }
        for url in entries where url.pathExtension.uppercased() == "PAK" {
            if let data = try? Data(contentsOf: url), let archive = try? Pak.Archive(data) { archives.append(archive) }
        }
        if let pal = data("IBM.PAL"), let p = try? Palette(pal) { palette = p }
        if let icn = data("ICON.ICN") { tileSet = try? Icn.TileSet(icn) }

        guard
            let mapData = data("ICON.MAP"),
            let iconMap = try? IconMap(mapData)
        else {
            error = "Missing ICON.MAP."; return
        }
        guard
            let emc = data("UNIT.EMC"),
            let program = try? Emc.Program(emc)
        else {
            error = "Missing UNIT.EMC."; return
        }
        guard
            let build = data("BUILD.EMC"),
            let buildProgram = try? Emc.Program(build)
        else {
            error = "Missing BUILD.EMC."; return
        }
        builder = ScenarioBuilder(
            iconMap: iconMap,
            unitScript: ScriptInfo(program),
            structureScript: ScriptInfo(buildProgram)
        )
        if tileSet == nil { error = "Missing ICON.ICN." }
    }

    func data(_ name: String) -> Data? {
        for archive in archives {
            if let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return archive.data(entry)
            }
        }
        return nil
    }

    func shp(_ name: String) -> Shp.FrameSet? {
        if let cached = shpCache[name] { return cached }
        guard let data = data(name), let set = try? Shp.FrameSet(data) else { return nil }
        shpCache[name] = set
        return set
    }
}
