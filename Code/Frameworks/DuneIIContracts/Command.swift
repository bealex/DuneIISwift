/// A player/input order to the simulation — the `input → sim` seam. Presentation-free: a unit is
/// identified by its pool index and a target by a packed map tile, so neither input nor the sim needs
/// the other's types. The simulation translates a `Command` into the same unit order the original game
/// issues from a viewport click (`GUI_Widget_Viewport_Click`, `src/gui/viewport.c`).
public enum Command: Sendable, Equatable {
    /// Order the unit to move to `tile` (a packed map position).
    case move(unit: UInt16, tile: UInt16)
    /// Order the unit to attack whatever is at/around `tile`.
    case attack(unit: UInt16, tile: UInt16)
    /// Order the unit (a harvester) to harvest at `tile` — move there and gather spice.
    case harvest(unit: UInt16, tile: UInt16)
    /// Order the unit to retreat toward `tile`.
    case retreat(unit: UInt16, tile: UInt16)
    /// Order the unit to stop — hold position and guard (clear its move/attack targets).
    case stop(unit: UInt16)
    /// Start the factory `structure` (a structure pool index) building `objectType` — a `UnitType.rawValue`
    /// for a unit factory, or a `StructureType.rawValue` for the construction yard (`Structure_BuildObject`).
    case build(structure: UInt16, objectType: UInt16)
    /// Order one `objectType` (`UnitType.rawValue`) from the starport `structure` — the CHOAM buy: chains it
    /// onto the house delivery list + decrements stock (`Structure_BuildObject`'s `FACTORY_BUY` body).
    case starportOrder(structure: UInt16, objectType: UInt16)
    /// Toggle the `structure`'s self-repair (`Structure_SetRepairingState`, −1 = toggle).
    case repair(structure: UInt16)
    /// Toggle the `structure`'s upgrade (`Structure_SetUpgradingState`, −1 = toggle).
    case upgrade(structure: UInt16)
    /// Cancel the factory `structure`'s in-progress build (`Structure_CancelBuild`; refunds the remainder).
    case cancelBuild(structure: UInt16)
    /// Place the construction yard `structure`'s finished (ready) structure at `tile` (a packed map
    /// position), then reset the factory (`Structure_Place` + the GUI place-flow reset).
    case placeStructure(structure: UInt16, tile: UInt16)
}
