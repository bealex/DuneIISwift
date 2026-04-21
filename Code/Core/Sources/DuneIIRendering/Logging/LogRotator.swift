import Foundation

/// Picks a per-run log file URL, creates the containing `Logs/`
/// directory, and deletes older run files beyond a capacity bound.
///
/// Files are named `run-YYYY-MM-DD_HH-MM-SS.log` so lexicographic
/// sort = chronological sort — the cleanup is just `keep the last N`.
public enum LogRotator {
    /// Picks a new run-file URL under `logsRoot` and, as a side-effect,
    /// trims older files so at most `keepLatest` remain (this run's
    /// file plus `keepLatest - 1` older ones).
    @discardableResult
    public static func prepareNewRunFile(
        logsRoot: URL,
        keepLatest: Int = 10
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: logsRoot, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let filename = "run-\(formatter.string(from: Date())).log"
        let url = logsRoot.appendingPathComponent(filename)

        rotate(logsRoot: logsRoot, keepLatest: max(keepLatest, 1))
        return url
    }

    /// Deletes older `run-*.log` files so at most `keepLatest - 1`
    /// remain (the next run adds its own file). Silently ignores
    /// enumeration / deletion failures — log rotation must not crash
    /// the app.
    private static func rotate(logsRoot: URL, keepLatest: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logsRoot, includingPropertiesForKeys: nil
        ) else { return }
        let runFiles = entries
            .filter { $0.lastPathComponent.hasPrefix("run-") && $0.pathExtension == "log" }
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        let toDelete = runFiles.dropFirst(max(keepLatest - 1, 0))
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }
}
