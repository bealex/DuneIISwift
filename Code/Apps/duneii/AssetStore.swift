import DuneIIContracts
import DuneIIFormats
import Foundation

/// Loads the original install's PAKs and exposes the assets the client needs: the tile set (`ICON.ICN` +
/// `ICON.MAP`), the palette (`IBM.PAL`), the unit sprite SHPs, sounds (VOC), and the scenario list.
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

    private(set) var scenarioNames: [String] = []

    static let grayscale: Palette = {
        var colors: [Palette.Color] = []
        for i in 0 ..< 256 { let v = UInt8(i / 4); colors.append(Palette.Color(red: v, green: v, blue: v)) }
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
            if let data = try? Data(contentsOf: url), let archive = try? Pak.Archive(data) { archives.append(archive) }
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

    func data(_ name: String) -> Data? {
        for archive in archives {
            if let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return archive.data(entry)
            }
        }
        return nil
    }

    func scenarioINI(_ name: String) -> Ini? { data(name).map { Ini($0) } }

    func shp(_ name: String) -> Shp.FrameSet? {
        if let cached = shpCache[name] { return cached }
        guard let data = data(name), let set = try? Shp.FrameSet(data) else { return nil }
        shpCache[name] = set
        return set
    }

    func voc(_ name: String) -> Voc.Sound? { data(name).flatMap { try? Voc.decode($0) } }

    /// The human player's house: the one flagged `Brain=Human` in the scenario INI (e.g. Atreides for
    /// SCENA001). `nil` if none is marked.
    static func playerHouse(in ini: Ini) -> HouseID? {
        for house in HouseID.allCases {
            if ini.string(section: house.displayName, key: "Brain")?.caseInsensitiveCompare("Human") == .orderedSame {
                return house
            }
        }
        return nil
    }
}
