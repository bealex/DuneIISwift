/// A fixed-size, **fully value-inline** array — `N` elements stored in place, no heap buffer, so copying it
/// is a trivial `memcpy` with **zero ARC** (no retain/release) and **zero allocation**. A thin wrapper over
/// the standard `InlineArray<N, Element>` that re-adds the `Codable`/`Equatable`/`Sendable` conformances the
/// stdlib type doesn't synthesise, so the model structs that embed it (`Unit`, `ScriptEngine`) keep their
/// own synthesised conformances unchanged.
///
/// Why this exists: the per-tick model structs used to hold heap `[T]` members (`Unit.route`,
/// `Unit.orientation`, `ScriptEngine.stack`/`.variables`). Every `let u = state.units[slot]` copy then did an
/// atomic retain/release on each shared COW buffer — the dominant cross-core contention that made the tick
/// fail to parallelize (see `Documentation/Architecture/Parallelization.md` §8). Storing them inline makes a
/// `Unit`/`Structure`/… a pure POD value: copies are free and ARC-free. Access is by `subscript`/`count`,
/// matching the former array API, so call sites are unchanged.
public struct Inline<let N: Int, Element>: Equatable, Sendable, Codable
where Element: Equatable & Sendable & Codable {
    public var storage: InlineArray<N, Element>

    public init(repeating value: Element) { storage = .init(repeating: value) }

    public subscript(_ index: Int) -> Element {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    public var count: Int { N }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        for i in 0 ..< N where lhs.storage[i] != rhs.storage[i] { return false }
        return true
    }

    // Codable — only ever exercised on the cold save/load path. Encodes as a flat array so the on-disk shape
    // matches the former `[Element]` (save round-trips stay structurally identical).
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var tmp: [Element] = []
        tmp.reserveCapacity(N)
        while !container.isAtEnd { tmp.append(try container.decode(Element.self)) }
        storage = .init { tmp[$0] }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for i in 0 ..< N { try container.encode(storage[i]) }
    }
}
