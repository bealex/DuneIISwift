import DuneIIFormats
import Foundation

/// Loads the original install's PAKs and exposes the assets the map view needs: the tile set
/// (`ICON.ICN` + `ICON.MAP`), the palette (`IBM.PAL`), the unit sprite SHPs, and the scenario list.
@MainActor
@Observable
final class AssetStore {
    let installURL: URL
    private(set) var error: String?

    private var archives: [Pak.Archive] = []
    private(set) var palette = AssetStore.grayscale
    private(set) var iconMap: IconMap?
    private(set) var tileSet: Icn.TileSet?
    private var shpCache: [String: Shp.FrameSet] = [:]

    /// Scenario `.INI` entry names available in the install (e.g. `SCENA001.INI`), sorted.
    private(set) var scenarioNames: [String] = []

    /// Fallback palette when `IBM.PAL` is missing.
    static let grayscale: Palette = {
        var colors: [Palette.Color] = []
        for i in 0 ..< 256 {
            let v = UInt8(i / 4)
            colors.append(Palette.Color(red: v, green: v, blue: v))
        }
        return Palette(colors: colors)
    }()

    init(installURL: URL) {
        self.installURL = installURL
        load()
    }

    private func load() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: installURL, includingPropertiesForKeys: nil) else {
            error = "Cannot read install directory: \(installURL.path)"
            return
        }
        for url in entries where url.pathExtension.uppercased() == "PAK" {
            if let data = try? Data(contentsOf: url), let archive = try? Pak.Archive(data) {
                archives.append(archive)
            }
        }
        if let pal = data("IBM.PAL"), let p = try? Palette(pal) { palette = p }
        if let map = data("ICON.MAP") { iconMap = try? IconMap(map) }
        if let icn = data("ICON.ICN") { tileSet = try? Icn.TileSet(icn) }

        var names = Set<String>()
        for archive in archives {
            for entry in archive.entries where entry.name.uppercased().hasPrefix("SCEN") && entry.name.uppercased().hasSuffix(".INI") {
                names.insert(entry.name.uppercased())
            }
        }
        scenarioNames = names.sorted()
        if iconMap == nil || tileSet == nil { error = (error ?? "") + " Missing ICON.MAP/ICON.ICN." }
    }

    /// The bytes of the first PAK entry named `name` (case-insensitive), or nil.
    func data(_ name: String) -> Data? {
        for archive in archives {
            if let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return archive.data(entry)
            }
        }
        return nil
    }

    func scenarioINI(_ name: String) -> Ini? {
        guard let data = data(name) else { return nil }
        return Ini(data)
    }

    /// A decoded (and cached) SHP frame set, e.g. `UNITS.SHP`.
    func shp(_ name: String) -> Shp.FrameSet? {
        if let cached = shpCache[name] { return cached }
        guard let data = data(name), let set = try? Shp.FrameSet(data) else { return nil }
        shpCache[name] = set
        return set
    }
}
