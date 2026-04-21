import Foundation
import DuneIICore

/// Locates the original Dune II 1.07 install and routes asset lookups
/// through the PAK catalog. The runtime uses this to fetch CPS / WSA /
/// SHP / PAL payloads on demand, avoiding the `assetgen`-into-`Resources/`
/// step for dev builds.
public struct Installation: Sendable {
    /// Directory containing `*.PAK` (and nothing else we care about here).
    public let rootDirectory: URL
    /// Every PAK under `rootDirectory`, sorted by filename.
    public let pakURLs: [URL]
    /// Lookup index: asset name (uppercased) → PAK archive + the PAK's URL.
    /// Built once at init time; lookups are O(1).
    private let index: [String: (pak: URL, archive: Formats.Pak.Archive)]

    public enum LocateError: Error, Sendable {
        case rootNotFound(URL)
        case noPaks(URL)
    }

    /// Opens every `*.PAK` in `rootDirectory`, builds the catalog, and
    /// keeps each archive handle live (PAK archives are lightweight —
    /// they only mmap once and the catalog fits in a few KB).
    public init(rootDirectory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else {
            throw LocateError.rootNotFound(rootDirectory)
        }
        let items = try fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        let paks = items
            .filter { $0.pathExtension.uppercased() == "PAK" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !paks.isEmpty else { throw LocateError.noPaks(rootDirectory) }

        var idx: [String: (URL, Formats.Pak.Archive)] = [:]
        for pak in paks {
            guard let archive = try? Formats.Pak.Archive(contentsOf: pak) else { continue }
            for entry in archive.entries {
                let key = entry.name.uppercased()
                // First-PAK-wins (mirrors OpenDUNE's `File_Open` search order).
                if idx[key] == nil { idx[key] = (pak, archive) }
            }
        }
        self.rootDirectory = rootDirectory
        self.pakURLs = paks
        self.index = idx
    }

    /// Fetches the raw body bytes of an asset by name. Case-insensitive.
    /// Returns nil if the asset isn't in any PAK.
    public func body(of assetName: String) -> Data? {
        guard let hit = index[assetName.uppercased()] else { return nil }
        return hit.archive.body(named: assetName)
    }

    /// Convenience: all assets whose name (uppercased) starts with `prefix`.
    /// Used by scenario browsers (`SCENA*` / `REGION*`).
    public func assetNames(startingWith prefix: String) -> [String] {
        let p = prefix.uppercased()
        return index.keys.filter { $0.hasPrefix(p) }.sorted()
    }

    // MARK: Discovery

    /// Walks up from `startingAt` looking for `Repositories/patched_107_unofficial`.
    /// Used by the app executable and by tests to locate the install without
    /// hard-coding a path.
    public static func discover(startingAt: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        var dir = startingAt
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
