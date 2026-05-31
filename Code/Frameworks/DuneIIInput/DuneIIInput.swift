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

/// The two map-targeted orders the inspector's buttons arm (then the next map click supplies the tile).
public enum OrderKind: Sendable, Hashable { case move, attack }

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
    /// The currently selected entity.
    public private(set) var selection: Selection = .none
    /// An order armed by an inspector button (`move`/`attack`); the next map click is its target.
    public private(set) var pendingOrder: OrderKind?
    private var queue: [Command] = []
    private let mapWidth: Int

    public init(mapWidth: Int = 64) { self.mapWidth = mapWidth }

    public mutating func drainCommands() -> [Command] { defer { queue.removeAll() }; return queue }

    /// A left-click on the map at tile `(x, y)`. With an order armed on a selected unit, this supplies the
    /// order's target (and disarms it); otherwise it selects `hit` (the entity the host resolved there, or
    /// `.none` to deselect).
    public mutating func leftClick(tileX x: Int, tileY y: Int, hit: Selection) {
        if let pending = pendingOrder, let slot = selection.unitSlot {
            queue.append(order(pending, slot: slot, tileX: x, tileY: y))
            pendingOrder = nil
        } else {
            selection = hit
            pendingOrder = nil
        }
    }

    /// A right-click on the map at tile `(x, y)`: order the selected unit. `enemyTarget` (the host resolved
    /// whether the tile holds an entity of a different house) chooses **attack** vs **move**.
    public mutating func rightClick(tileX x: Int, tileY y: Int, enemyTarget: Bool) {
        guard let slot = selection.unitSlot else { return }
        queue.append(order(enemyTarget ? .attack : .move, slot: slot, tileX: x, tileY: y))
        pendingOrder = nil
    }

    /// Arm an order from an inspector button (no-op unless a unit is selected).
    public mutating func beginOrder(_ kind: OrderKind) { if selection.unitSlot != nil { pendingOrder = kind } }

    /// Stop the selected unit immediately (the inspector's Stop button).
    public mutating func stopSelected() {
        if let slot = selection.unitSlot { queue.append(.stop(unit: UInt16(slot))) }
        pendingOrder = nil
    }

    /// Clear the selection + any armed order (Escape).
    public mutating func deselect() { selection = .none; pendingOrder = nil }

    private func order(_ kind: OrderKind, slot: Int, tileX x: Int, tileY y: Int) -> Command {
        let tile = UInt16(y * mapWidth + x)
        switch kind {
            case .move:   return .move(unit: UInt16(slot), tile: tile)
            case .attack: return .attack(unit: UInt16(slot), tile: tile)
        }
    }
}
