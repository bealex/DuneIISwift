import Foundation
import Testing
import Memoirs
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Logging — FileMemoir + LogRotator + compile-time guard")
struct LoggingTests {

    // MARK: FileMemoir

    @Test("FileMemoir writes a line containing the message + level tag")
    func fileMemoirWritesLogLine() throws {
        let tmp = try tempFile(suffix: "log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memoir = try FileMemoir(url: tmp)
        memoir.append(
            .log(level: .debug),
            message: "hello world",
            meta: nil,
            tracers: [.label("unit-test")],
            timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate,
            file: "LoggingTests.swift", function: "func()", line: 42
        )

        // FileMemoir flushes asynchronously — give the queue a beat.
        try Self.waitUntilFileContains(tmp, substring: "hello world")
        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(contents.contains("hello world"))
        #expect(contents.contains("DBG"))
        #expect(contents.contains("unit-test"))
        #expect(contents.contains("LoggingTests.swift:42"))
    }

    @Test("FileMemoir appends rather than truncating on reopen")
    func fileMemoirAppends() throws {
        let tmp = try tempFile(suffix: "log")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let m1 = try FileMemoir(url: tmp)
        m1.append(
            .log(level: .info),
            message: "first",
            meta: nil, tracers: [],
            timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate,
            file: "a", function: "b", line: 1
        )
        try Self.waitUntilFileContains(tmp, substring: "first")

        let m2 = try FileMemoir(url: tmp)
        m2.append(
            .log(level: .info),
            message: "second",
            meta: nil, tracers: [],
            timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate,
            file: "a", function: "b", line: 1
        )
        try Self.waitUntilFileContains(tmp, substring: "second")

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(contents.contains("first"))
        #expect(contents.contains("second"))
    }

    // MARK: LogRotator

    @Test("LogRotator creates the Logs directory + returns a run-*.log URL")
    func rotatorCreatesRunFile() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try LogRotator.prepareNewRunFile(logsRoot: root, keepLatest: 10)
        #expect(url.lastPathComponent.hasPrefix("run-"))
        #expect(url.pathExtension == "log")
        // Parent directory exists.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("LogRotator keeps only the newest keepLatest-1 files + the new one")
    func rotatorTrimsOlderFiles() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // Seed 5 old run files with lexicographically-ordered names.
        for i in 0..<5 {
            let url = root.appendingPathComponent("run-2020-01-0\(i)_00-00-00.log")
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        // Ask to keep 3 total (newest 2 + the new one).
        _ = try LogRotator.prepareNewRunFile(logsRoot: root, keepLatest: 3)
        let remaining = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("run-") }
        #expect(remaining.count == 2,
                "should leave the 2 newest prior run files; got \(remaining.count)")
        // The two newest by lexicographic sort — run-2020-01-04 and run-2020-01-03.
        let names = Set(remaining.map(\.lastPathComponent))
        #expect(names.contains("run-2020-01-04_00-00-00.log"))
        #expect(names.contains("run-2020-01-03_00-00-00.log"))
    }

    // MARK: Log facade

    @Test("Log.setup installs the memoir and Log.debug routes through it")
    func logFacadeRoutesThroughMemoir() throws {
        let tmp = try tempFile(suffix: "log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memoir = try FileMemoir(url: tmp)
        Log.setup(memoir: memoir)
        defer { Log.setup(memoir: VoidMemoir()) } // reset after

        Log.debug("route-test-line")
        try Self.waitUntilFileContains(tmp, substring: "route-test-line")
        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(contents.contains("route-test-line"))
    }

    // MARK: Helpers

    private func tempFile(suffix: String) throws -> URL {
        let dir = try tempDirectory()
        return dir.appendingPathComponent("test.\(suffix)")
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuneIILogging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Poll the file for up to 2 s, since `FileMemoir`'s writes go
    /// through a serial queue.
    static func waitUntilFileContains(_ url: URL, substring: String) throws {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.contains(substring) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Issue.record("file \(url.lastPathComponent) never contained \"\(substring)\"")
    }
}
