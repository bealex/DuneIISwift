import Foundation

/// Locates the user's original Dune II install under
/// `Repositories/patched_107_unofficial/` relative to the test source tree.
/// Tests that depend on real data call this and short-circuit when it
/// returns nil, so the suite still runs on machines without the install.
enum TestInstall {
    static func locate() -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
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
