import Foundation
import Memoirs

/// Thin, compile-time-gated wrapper around a `Memoirs.Memoir`. All log
/// calls compile to nothing in release builds (no autoclosure evaluation,
/// no memoir.append calls), so there's no runtime cost when shipping.
///
/// Usage:
/// ```
/// Log.debug("unit \(idx) action \(action)")
/// Log.warning("halted on slot \(slot)")
/// ```
///
/// Configuration happens once at process startup:
/// ```
/// Log.setup(memoir: FileMemoir(url: ...))
/// ```
///
/// See `DuneIIRendering/Logging/FileMemoir.swift` for the rotating file
/// implementation the `duneii` executable installs.
public enum Log {
    /// The active memoir. Only read/written in DEBUG builds; release
    /// builds compile every call below to a no-op so this storage is
    /// never touched.
    ///
    /// Backed by a nonisolated lock because logging must work from any
    /// thread (scheduler ticks, SpriteKit `update`, test harnesses).
    /// Memoirs conforms to `Sendable` so we can hand it across threads
    /// safely; the lock only guards the `memoir` pointer swap.
    #if DEBUG
    nonisolated(unsafe) private static var memoir: Memoir = VoidMemoir()
    private static let memoirLock = NSLock()

    /// Install a memoir. Safe to call once at process start. Subsequent
    /// calls replace the previous installation.
    public static func setup(memoir newValue: Memoir) {
        memoirLock.lock()
        memoir = newValue
        memoirLock.unlock()
    }

    public static func current() -> Memoir {
        memoirLock.lock()
        defer { memoirLock.unlock() }
        return memoir
    }
    #else
    public static func setup(memoir _: Any) {}
    #endif

    // MARK: - Level-specific methods

    @inlinable
    public static func verbose(
        _ message: @autoclosure () -> SafeString,
        tracer: Tracer? = nil,
        meta: @autoclosure () -> [String: SafeString]? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        #if DEBUG
        append(.log(level: .verbose), message: message(),
               tracer: tracer, meta: meta(),
               file: file, function: function, line: line)
        #endif
    }

    @inlinable
    public static func debug(
        _ message: @autoclosure () -> SafeString,
        tracer: Tracer? = nil,
        meta: @autoclosure () -> [String: SafeString]? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        #if DEBUG
        append(.log(level: .debug), message: message(),
               tracer: tracer, meta: meta(),
               file: file, function: function, line: line)
        #endif
    }

    @inlinable
    public static func info(
        _ message: @autoclosure () -> SafeString,
        tracer: Tracer? = nil,
        meta: @autoclosure () -> [String: SafeString]? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        #if DEBUG
        append(.log(level: .info), message: message(),
               tracer: tracer, meta: meta(),
               file: file, function: function, line: line)
        #endif
    }

    @inlinable
    public static func warning(
        _ message: @autoclosure () -> SafeString,
        tracer: Tracer? = nil,
        meta: @autoclosure () -> [String: SafeString]? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        #if DEBUG
        append(.log(level: .warning), message: message(),
               tracer: tracer, meta: meta(),
               file: file, function: function, line: line)
        #endif
    }

    @inlinable
    public static func error(
        _ message: @autoclosure () -> SafeString,
        tracer: Tracer? = nil,
        meta: @autoclosure () -> [String: SafeString]? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        #if DEBUG
        append(.log(level: .error), message: message(),
               tracer: tracer, meta: meta(),
               file: file, function: function, line: line)
        #endif
    }

    // MARK: - Internal

    #if DEBUG
    @usableFromInline
    static func append(
        _ item: MemoirItem,
        message: @autoclosure () -> SafeString,
        tracer: Tracer?,
        meta: @autoclosure () -> [String: SafeString]?,
        file: String, function: String, line: UInt
    ) {
        let m = current()
        m.append(
            item, message: message(), meta: meta(),
            tracers: tracer.map { [$0] } ?? [],
            timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate,
            file: file, function: function, line: line
        )
    }
    #endif
}
