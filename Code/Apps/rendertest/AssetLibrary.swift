import AVFoundation
import DuneIIAudio
import DuneIIExport
import DuneIIFormats
import DuneIIRenderer
import Foundation
import Observation

/// Loads the original install's PAKs and exposes their contents as a browsable, categorized asset
/// list. Decoding happens on demand in the views; this model owns the raw archives, the default
/// palette (IBM.PAL), and a sound player. A synthetic "Units" category splits the unit SHP files into
/// logical per-unit sprite groups via `SpriteCatalog`.
@MainActor
@Observable
final class AssetLibrary {
    struct Asset: Identifiable, Hashable {
        enum Kind: String, CaseIterable {
            case sprite = "Sprites"
            case image = "Images"
            case tiles = "Tiles"
            case animation = "Animations"
            case font = "Fonts"
            case sound = "Sounds"
            case music = "Music"  // synthetic: a DUNE<file>.ADL track (AdLib FM / OPL3 preview)
            case script = "Scripts"
            case iconGroup = "Icon Group"  // synthetic: an ICON.MAP icon group (building / terrain)
        }

        let id: String
        let pak: String
        let name: String  // the PAK entry filename (what to load)
        let kind: Kind
        let displayName: String  // sidebar label (a unit name for groups, else the filename)
        let frameRange: Range<Int>?  // a sub-range of an SHP's frames, for unit groups
        let groupKind: SpriteCatalog.GroupKind?
        let iconGroup: Int?  // an ICON.MAP group index, for building / terrain assets
        let music: (file: Int, song: Int)?  // a music track's (DUNE<file>.ADL, subsong), for `.music` assets

        init(
            pak: String,
            name: String,
            kind: Kind,
            displayName: String? = nil,
            frameRange: Range<Int>? = nil,
            groupKind: SpriteCatalog.GroupKind? = nil,
            iconGroup: Int? = nil,
            music: (file: Int, song: Int)? = nil
        ) {
            self.pak = pak
            self.name = name
            self.kind = kind
            self.displayName = displayName ?? name
            self.frameRange = frameRange
            self.groupKind = groupKind
            self.iconGroup = iconGroup
            self.music = music
            let isSubAsset = frameRange != nil || iconGroup != nil || music != nil
            self.id = isSubAsset ? "\(pak)/\(name)#\(self.displayName)" : "\(pak)/\(name)"
        }

        static func == (lhs: Asset, rhs: Asset) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    struct Category: Identifiable {
        let id: String
        let title: String
        let assets: [Asset]
    }

    let installURL: URL
    private(set) var categories: [Category] = []
    private(set) var palette: Palette
    private(set) var loadError: String?

    private var archives: [String: Pak.Archive] = [:]
    private var player: AVAudioPlayer?

    /// Where the `DUNE<file>.ADL` music files live (separate from the PAK install), if found, plus the lazily
    /// created OPL3 AdLib player that previews them.
    private(set) var musicDirectory: URL?
    private var musicPlayer: ADLMusicPlayer?

    init(installURL: URL) {
        self.installURL = installURL
        self.palette = AssetLibrary.loadPalette(installURL) ?? AssetLibrary.monochromePalette()
        self.musicDirectory = AssetLibrary.locateMusicDirectory()
        loadCategories()
    }

    // MARK: - Music preview (AdLib FM / OPL3)

    /// Preview a music track through the authentic AdLib FM (OPL3) synth. Lazily spins up the player + audio
    /// engine on first use.
    func playMusic(file: Int, song: Int, loop: Bool) {
        guard let dir = musicDirectory else { return }
        if musicPlayer == nil { musicPlayer = ADLMusicPlayer(musicDirectory: dir) }
        musicPlayer?.play(file: file, song: song, loop: loop)
    }

    func stopMusic() { musicPlayer?.stop() }
    func pauseMusic() { musicPlayer?.pause() }
    func resumeMusic() { musicPlayer?.resume() }

    /// Find the `Audio/Music` directory holding `DUNE<file>.ADL` — bundled next to the executable, or the
    /// repo's `Resources/Audio/Music` (the `swift run rendertest`-from-`Code/` layout). Nil ⇒ no music preview.
    private static func locateMusicDirectory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Audio/Music"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("../Resources/Audio/Music"))
        candidates.append(cwd.appendingPathComponent("Resources/Audio/Music"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DUNE1.ADL").path) }
    }

    func data(for asset: Asset) -> Data? {
        archives[asset.pak]?.data(named: asset.name)
    }

    func data(pak: String, name: String) -> Data? {
        archives[pak]?.data(named: name)
    }

    /// A raw 256-color `.PAL` file (768 bytes) loaded by name from any PAK, or nil if absent. Used for
    /// the context palettes of assets that carry none of their own — `BENE.PAL` (mercenary mentat),
    /// `INTRO.PAL` (intro / finale cutscene animations).
    func palette(named name: String) -> Palette? {
        for archive in archives.values {
            if let data = archive.data(named: name), let palette = try? Palette(data) { return palette }
        }
        return nil
    }

    func playSound(_ sound: Voc.Sound) {
        let wav = WavWriter.encode(samples: sound.samples, sampleRate: max(sound.sampleRate, 1))
        player = try? AVAudioPlayer(data: wav)
        player?.play()
    }

    private func loadCategories() {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(at: installURL, includingPropertiesForKeys: nil)
        else {
            loadError = "Cannot read install directory: \(installURL.path)"
            return
        }

        var fileAssets: [Asset.Kind: [Asset]] = [:]
        var shpToPak: [String: String] = [:]  // uppercased SHP filename -> containing PAK
        let paks =
            entries
            .filter { $0.pathExtension.uppercased() == "PAK" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for pak in paks {
            guard let data = try? Data(contentsOf: pak), let archive = try? Pak.Archive(data) else { continue }

            let pakName = pak.deletingPathExtension().lastPathComponent
            archives[pakName] = archive
            for entry in archive.entries {
                guard let kind = AssetLibrary.kind(for: entry.name) else { continue }

                fileAssets[kind, default: []].append(Asset(pak: pakName, name: entry.name, kind: kind))
                if kind == .sprite { shpToPak[entry.name.uppercased()] = pakName }
            }
        }

        let categories = Asset.Kind.allCases.compactMap { kind -> Category? in
            guard let assets = fileAssets[kind], !assets.isEmpty else { return nil }

            return Category(
                id: kind.rawValue,
                title: kind.rawValue,
                assets: assets.sorted { $0.displayName < $1.displayName }
            )
        }

        let unitAssets: [Asset] = SpriteCatalog.unitGroups.compactMap { group in
            guard let pak = shpToPak[group.shp.uppercased()] else { return nil }

            return Asset(
                pak: pak,
                name: group.shp,
                kind: .sprite,
                displayName: group.label,
                frameRange: group.firstFrame ..< (group.firstFrame + group.frameCount),
                groupKind: group.kind
            )
        }
        var special: [Category] = []
        if !unitAssets.isEmpty {
            special.append(Category(id: "Units", title: "Units", assets: unitAssets))
        }

        // Buildings & terrain: ICON.ICN tiles grouped by ICON.MAP icon groups.
        if let iconAsset = fileAssets[.tiles]?.first(where: { $0.name.uppercased() == "ICON.ICN" }),
            let mapData = archives[iconAsset.pak]?.data(named: "ICON.MAP"),
            let iconMap = try? IconMap(mapData)
        {
            func groupAsset(_ group: IconMap.Group) -> Asset {
                Asset(
                    pak: iconAsset.pak,
                    name: iconAsset.name,
                    kind: .iconGroup,
                    displayName: group.name,
                    iconGroup: group.index
                )
            }

            let buildings = iconMap.groups.filter { $0.isBuilding && !$0.tileIDs.isEmpty }.map(groupAsset)
            let terrain = iconMap.groups.filter { !$0.isBuilding && !$0.tileIDs.isEmpty }.map(groupAsset)
            if !buildings.isEmpty { special.append(Category(id: "Buildings", title: "Buildings", assets: buildings)) }
            if !terrain.isEmpty { special.append(Category(id: "Terrain", title: "Terrain", assets: terrain)) }
        }

        // Music: every `g_table_musics` track whose `DUNE<file>.ADL` is present, as AdLib/OPL3 previews.
        if let dir = musicDirectory {
            let musicAssets: [Asset] = MusicDirector.previewTracks.compactMap { track in
                guard
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent("DUNE\(track.file).ADL").path)
                else { return nil }
                return Asset(
                    pak: "MUSIC",
                    name: "\(track.id)",
                    kind: .music,
                    displayName: track.name,
                    music: (file: track.file, song: track.song)
                )
            }
            if !musicAssets.isEmpty { special.append(Category(id: "Music", title: "Music", assets: musicAssets)) }
        }

        self.categories = special + categories
        if self.categories.isEmpty, loadError == nil { loadError = "No assets found in \(installURL.path)" }
    }

    private static func kind(for name: String) -> Asset.Kind? {
        switch (name as NSString).pathExtension.uppercased() {
            case "SHP": return .sprite
            case "CPS": return .image
            case "ICN": return .tiles
            case "WSA": return .animation
            case "FNT": return .font
            case "VOC": return .sound
            case "EMC": return .script
            default: return nil
        }
    }

    private static func loadPalette(_ installURL: URL) -> Palette? {
        guard
            let data = try? Data(contentsOf: installURL.appendingPathComponent("DUNE.PAK")),
            let archive = try? Pak.Archive(data),
            let paletteData = archive.data(named: "IBM.PAL")
        else { return nil }

        return try? Palette(paletteData)
    }

    private static func monochromePalette() -> Palette {
        var bytes = [ UInt8 ](repeating: 0, count: 768)
        for index in 0 ..< 256 {
            let value = UInt8(index >> 2)
            bytes[index * 3] = value
            bytes[index * 3 + 1] = value
            bytes[index * 3 + 2] = value
        }
        return try! Palette(Data(bytes))
    }
}
