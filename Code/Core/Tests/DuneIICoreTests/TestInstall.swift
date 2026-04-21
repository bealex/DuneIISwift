import Foundation

/// Locates the user's original Dune II install under
/// `Repositories/patched_107_unofficial/` relative to the test source tree.
/// Tests that depend on real data call this and short-circuit when it
/// returns nil, so the suite still runs on machines without the install.
///
/// Readability check: when running from a git worktree, the install may
/// resolve via a sibling path but be outside the sandbox's permitted
/// roots. `fileExists` returns `true` for such paths but reading fails
/// with POSIX `Operation not permitted`. Require the directory to be
/// readable (via `contentsOfDirectory`) so install-gated tests skip
/// instead of fail in that case.
enum TestInstall {
    static func locate() -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path),
               (try? FileManager.default.contentsOfDirectory(atPath: candidate.path)) != nil {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
