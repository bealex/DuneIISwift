import DuneIIContracts

/// Input — the `input → sim` driver. An `InputSource` produces `Command`s the host applies to the
/// simulation between ticks; the interactive `InputController` (the selection + order state machine) and
/// `ScriptedInput` (a fixed command list, for headless test scenarios) both conform. Depends only on
/// `DuneIIContracts` — never on the simulation. Selection is **presentation-local** state (the sim has no
/// "selected" concept); the host resolves a clicked tile to the entity there and hands the controller a
/// `Selection`, which it tracks and turns into `move`/`attack`/`stop` `Command`s.

/// What the player has selected. A unit/structure is named by its **pool slot** (the host's GameState
/// array index) — the same identifier a `Command` carries.
public enum Selection: Sendable, Equatable {
    case none
    case unit(slot: Int)
    case structure(slot: Int)

    public var unitSlot: Int? { if case let .unit(slot) = self { return slot }; return nil }
    public var isEmpty: Bool { self == .none }
}

/// The map-targeted orders a keyboard shortcut / inspector button arms (then the next map click supplies
/// the tile): `m`ove, `a`ttack, `h`arvest, `r`etreat. (`s`top is immediate — no target — via `stopSelected`.)
public enum OrderKind: Sendable, Hashable { case move, attack, harvest, retreat }

/// A unit's tile offset from its group's anchor — the stored **formation**. When a multi-unit group moves,
/// each unit is sent to the destination tile plus its offset, so the group keeps its relative arrangement
/// instead of piling onto one tile. Captured by the host at selection time from the units' live positions.
public struct TileOffset: Sendable, Equatable {
    public var dx: Int
    public var dy: Int

    public init(dx: Int, dy: Int) {
        self.dx = dx
        self.dy = dy
    }
}

/// A source of player `Command`s, drained by the host once per tick.
public protocol InputSource: Sendable {
    /// Return and clear the commands queued since the last drain.
    mutating func drainCommands() -> [Command]
}

/// A fixed command list (headless test scenarios / scripted playback).
public struct ScriptedInput: InputSource {
    private var queue: [Command]

    public init(_ commands: [Command] = []) { queue = commands }

    public mutating func enqueue(_ command: Command) { queue.append(command) }

    public mutating func drainCommands() -> [Command] { defer { queue.removeAll() }; return queue }
}

/// The interactive selection + order state machine. The host feeds it clicks (with the entity the host
/// resolved at the tile) and inspector button presses; it tracks the current `selection` + an armed
/// `pendingOrder`, and queues `Command`s for the host to drain. Pure value type — fully unit-testable.
public struct InputController: InputSource {
    /// The currently selected entity — drives the inspector. For a multi-unit (drag) selection this is the
    /// first unit of `selectedUnits`; for a structure it is that structure.
    public private(set) var selection: Selection = .none
    /// The group of player units orders apply to. A single unit-click sets `[that unit]`; a drag-select sets
    /// the whole group; selecting a structure / empty ground clears it. (The original Dune II selects one unit
    /// at a time — group select is a verification-client convenience.)
    public private(set) var selectedUnits: [Int] = []
    /// An order armed by an inspector button (`move`/`attack`); the next map click is its target.
    public private(set) var pendingOrder: OrderKind?
    /// The selected group's formation: each unit's tile offset from the **leader** (the first/clicked unit),
    /// applied to `move` orders so the group keeps its shape. Empty ⇒ no formation (every unit targets the
    /// exact clicked tile). The leader's own offset is `(0,0)` — a move sends it to the clicked tile.
    public private(set) var formation: [Int: TileOffset] = [:]
    /// The group's leader — its first (clicked) unit. Move orders treat the clicked tile as the leader's
    /// destination and place the rest relative to it; the host marks it with a flag. `nil` unless ≥2 selected.
    public var leaderSlot: Int? { selectedUnits.count > 1 ? selectedUnits.first : nil }
    private var queue: [Command] = []
    private let mapWidth: Int
    private let mapHeight: Int

    public init(mapWidth: Int = 64, mapHeight: Int = 64) {
        self.mapWidth = mapWidth
        self.mapHeight = mapHeight
    }

    public mutating func drainCommands() -> [Command] { defer { queue.removeAll() }; return queue }

    /// A left-click on the map at tile `(x, y)`. With an order armed on the selected unit(s), this supplies the
    /// order's target for every selected unit (and disarms it); otherwise it selects `hit` (the entity the host
    /// resolved there, or `.none` to deselect) as a single-unit/structure selection.
    public mutating func leftClick(tileX x: Int, tileY y: Int, hit: Selection) {
        if let pending = pendingOrder, !selectedUnits.isEmpty {
            for slot in selectedUnits { queue.append(order(pending, slot: slot, tileX: x, tileY: y)) }
            pendingOrder = nil
        } else {
            selection = hit
            selectedUnits = hit.unitSlot.map { [ $0 ] } ?? []
            formation = [:]
            pendingOrder = nil
        }
    }

    /// Reduce a drag-selected set to its **dominant unit type** — the single most-numerous type in the box
    /// (ties broken by the lowest type id, for determinism). A mixed-type group can't share one order (a
    /// harvester can't attack, a tank can't harvest), so a drag selects only the majority type. `typeOf`
    /// maps a slot to its unit-type id. Returns the kept slots (sorted); `[]` for an empty input.
    public static func dominantGroup(_ slots: [Int], typeOf: (Int) -> Int) -> [Int] {
        let groups = Dictionary(grouping: slots, by: typeOf)
        guard
            let best = groups.max(by: { l, r in
                l.value.count != r.value.count ? l.value.count < r.value.count : l.key > r.key
            })
        else { return [] }

        return best.value.sorted()
    }

    /// The connected cluster of same-type units reachable from the clicked unit by hops of at most `radius`
    /// tiles (Chebyshev) — the "double-click a unit selects the local group" behaviour. The host pre-filters
    /// `units` to the eligible same-type slots (player-owned, on-map, normal) and supplies each one's tile.
    /// Starting at `clicked`, the set grows to include any unit within `radius` of a unit *already* in it, so
    /// a continuous row/column of units is fully selected — not merely those within `radius` of the click.
    /// Returns the cluster's slots (sorted), or `[]` if `clicked` isn't among `units` (the host then falls
    /// back to a plain single select).
    public static func clusterGroup(_ units: [(slot: Int, x: Int, y: Int)], clicked: Int, radius: Int) -> [Int] {
        guard let seed = units.first(where: { $0.slot == clicked }) else { return [] }

        var included: Set<Int> = [ seed.slot ]
        var frontier = [ seed ]
        while let cur = frontier.popLast() {
            for u in units
                where !included.contains(u.slot) && abs(u.x - cur.x) <= radius && abs(u.y - cur.y) <= radius {
                included.insert(u.slot)
                frontier.append(u)
            }
        }
        return included.sorted()
    }

    /// Replace the selection with a group of player unit slots (drag / double- or triple-click / control-group
    /// recall — the host computes which units). `selection` mirrors the first for the inspector; empty ⇒
    /// deselect. `formation` records each unit's tile offset from the group anchor so a later `move` keeps the
    /// arrangement (pass `[:]` for none).
    public mutating func selectGroup(_ units: [Int], formation: [Int: TileOffset] = [:]) {
        selectedUnits = units
        self.formation = formation
        selection = units.first.map { .unit(slot: $0) } ?? .none
        pendingOrder = nil
    }

    /// A right-click on the map at tile `(x, y)`: order **every** selected unit with the default contextual
    /// action. The host resolves the facts it needs the world model for: `enemyTarget` (the tile holds an
    /// entity of a different house ⇒ attack) and `harvester` (a *single* selected harvester ⇒ Harvest, its
    /// `actionsPlayer[0]`; the host passes `false` for a multi-unit group). Harvester wins; else enemy ⇒
    /// attack, else move. The same kind is issued to the whole group.
    public mutating func rightClick(tileX x: Int, tileY y: Int, enemyTarget: Bool, harvester: Bool) {
        guard !selectedUnits.isEmpty else { return }

        let kind: OrderKind = harvester ? .harvest : (enemyTarget ? .attack : .move)
        for slot in selectedUnits { queue.append(order(kind, slot: slot, tileX: x, tileY: y)) }
        pendingOrder = nil
    }

    /// Arm an order from an inspector button (no-op unless ≥1 unit is selected).
    public mutating func beginOrder(_ kind: OrderKind) { if !selectedUnits.isEmpty { pendingOrder = kind } }

    /// Stop every selected unit immediately (the inspector's Stop button).
    public mutating func stopSelected() {
        for slot in selectedUnits { queue.append(.stop(unit: UInt16(slot))) }
        pendingOrder = nil
    }

    /// Clear the selection + any armed order (Escape).
    public mutating func deselect() {
        selection = .none
        selectedUnits = []
        formation = [:]
        pendingOrder = nil
    }

    private func order(_ kind: OrderKind, slot: Int, tileX x: Int, tileY y: Int) -> Command {
        // A `move` keeps formation: send each unit to the destination plus its stored offset (clamped to the
        // map). Other orders (attack/harvest/retreat) target the exact tile for the whole group.
        var tx = x, ty = y
        if kind == .move, let off = formation[slot] {
            tx = min(max(x + off.dx, 0), mapWidth - 1)
            ty = min(max(y + off.dy, 0), mapHeight - 1)
        }
        let tile = UInt16(ty * mapWidth + tx)
        return switch kind {
            case .move: .move(unit: UInt16(slot), tile: tile)
            case .attack: .attack(unit: UInt16(slot), tile: tile)
            case .harvest: .harvest(unit: UInt16(slot), tile: tile)
            case .retreat: .retreat(unit: UInt16(slot), tile: tile)
        }
    }
}
