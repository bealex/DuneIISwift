/// A player/input order to the simulation — the `input → sim` seam. Presentation-free: a unit is
/// identified by its pool index and a target by a packed map tile, so neither input nor the sim needs
/// the other's types. The simulation translates a `Command` into the same unit order the original game
/// issues from a viewport click (`GUI_Widget_Viewport_Click`, `src/gui/viewport.c`).
public enum Command: Sendable, Equatable {
    /// Order the unit to move to `tile` (a packed map position).
    case move(unit: UInt16, tile: UInt16)
    /// Order the unit to attack whatever is at/around `tile`.
    case attack(unit: UInt16, tile: UInt16)
    /// Order the unit to stop — hold position and guard (clear its move/attack targets).
    case stop(unit: UInt16)
}
