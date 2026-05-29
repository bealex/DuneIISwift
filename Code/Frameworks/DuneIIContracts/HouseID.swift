/// The six houses, in the engine's canonical order. A port of OpenDUNE's `HouseType`
/// (`src/house.h:9`); `rawValue` matches `HOUSE_HARKONNEN … HOUSE_MERCENARY` (0…5). The original's
/// `HOUSE_INVALID` (0xFF) is represented by an optional `HouseID?` rather than a case.
///
/// Lives in Contracts as a shared seam identifier (sim ↔ render ↔ input ↔ save).
public enum HouseID: Int, CaseIterable, Sendable {
    case harkonnen = 0
    case atreides = 1
    case ordos = 2
    case fremen = 3
    case sardaukar = 4
    case mercenary = 5
}
