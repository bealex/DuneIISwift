import DuneIIFormats
import Foundation

/// Locates the original 1.07 install (read-only, git-ignored) so real-data tests can run against it,
/// and short-circuit cleanly when it is absent. The install lives at `Repositories/patched_107_unofficial`
/// relative to the repo root, which is four directories up from this source file
/// (`Code/Tests/FormatsTests/TestInstall.swift`).
enum TestInstall {
    static var url: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let install = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: install.path) ? install : nil
    }

    /// The raw bytes of an install file (e.g. `"DUNE.PAK"`), or nil when the install is absent.
    static func data(_ name: String) -> Data? {
        guard let url else { return nil }

        return try? Data(contentsOf: url.appendingPathComponent(name))
    }

    /// The bytes of the first entry in install PAK `pakName` whose name ends with `suffix`
    /// (case-insensitive), or nil when the install or a matching entry is absent. Lets real-data
    /// tests reach assets that live inside PAKs (e.g. ICON.ICN inside DUNE.PAK).
    static func pakEntry(_ pakName: String, matchingSuffix suffix: String) -> Data? {
        guard let pakData = data(pakName), let archive = try? Pak.Archive(pakData) else { return nil }

        let wanted = suffix.uppercased()
        guard let entry = archive.entries.first(where: { $0.name.uppercased().hasSuffix(wanted) }) else { return nil }

        return archive.data(entry)
    }
}
