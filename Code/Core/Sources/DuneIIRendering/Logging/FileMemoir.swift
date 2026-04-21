import Foundation
import Memoirs

/// `Memoir` implementation that appends log lines to a file handle.
/// Mirrors `PrintMemoir`'s default line format for readability:
/// `[HH:mm:ss.SSS] level label [file:line func] message`.
///
/// Writes are serialised through an internal `DispatchQueue` so the
/// logger is safe to call from any thread. The file handle is flushed
/// on every append — worth the IO cost for crash-diagnostic use where
/// buffered lines would be lost.
public final class FileMemoir: Memoir, @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "DuneII.FileMemoir")
    private let dateFormatter: DateFormatter

    public init(handle: FileHandle) {
        self.handle = handle
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = f
    }

    /// Convenience: open the given URL for appending, creating the file
    /// (and its parent directory) as needed. Throws on permission /
    /// filesystem errors.
    public convenience init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.init(handle: handle)
    }

    public func append(
        _ item: MemoirItem,
        message: @autoclosure () throws -> SafeString,
        meta: @autoclosure () -> [String: SafeString]?,
        tracers: [Tracer],
        timeIntervalSinceReferenceDate: TimeInterval,
        file: String, function: String, line: UInt
    ) rethrows {
        let date = Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate)
        let timestamp = dateFormatter.string(from: date)
        let codePos = Self.shortCodePosition(file: file, function: function, line: line)
        let tracerLabel = tracers.first.map { " [\($0.string)]" } ?? ""
        let metaSnapshot = meta()
        let metaSuffix = metaSnapshot.map { d -> String in
            let pairs = d.map { "\($0)=\($1)" }
            return pairs.isEmpty ? "" : " {\(pairs.joined(separator: ", "))}"
        } ?? ""

        let line: String
        switch item {
        case .log(let level):
            let rendered = (try? Self.render(message())) ?? "<log-message-error>"
            line = "[\(timestamp)] \(Self.levelTag(level))\(tracerLabel) \(codePos) \(rendered)\(metaSuffix)\n"
        case .event(let name):
            line = "[\(timestamp)] EVENT\(tracerLabel) \(codePos) \(name)\(metaSuffix)\n"
        case .measurement(let name, let value):
            line = "[\(timestamp)] MEASURE\(tracerLabel) \(codePos) \(name) = \(value)\(metaSuffix)\n"
        case .tracer(let tracer, let finished):
            line = "[\(timestamp)] TRACER\(tracerLabel) \(codePos) \(tracer.string) \(finished ? "END" : "BEGIN")\n"
        }

        guard let data = line.data(using: .utf8) else { return }
        queue.async { [handle] in
            try? handle.write(contentsOf: data)
        }
    }

    /// `SafeString` renders as a description string via `String(describing:)`.
    /// We treat every value as safe (dev-only file logs — no PII).
    private static func render(_ safe: SafeString) -> String {
        String(describing: safe)
    }

    private static func levelTag(_ level: LogLevel) -> String {
        switch level {
        case .verbose:  return "VRB"
        case .debug:    return "DBG"
        case .info:     return "INF"
        case .warning:  return "WRN"
        case .error:    return "ERR"
        case .critical: return "CRT"
        }
    }

    private static func shortCodePosition(file: String, function: String, line: UInt) -> String {
        // `#fileID` format is `Module/Subpath/File.swift`. We keep the
        // file basename only and join with `:line` / `func`.
        let fileOnly = (file as NSString).lastPathComponent
        let funcOnly = function.split(separator: "(").first.map(String.init) ?? function
        return "[\(fileOnly):\(line) \(funcOnly)]"
    }
}
