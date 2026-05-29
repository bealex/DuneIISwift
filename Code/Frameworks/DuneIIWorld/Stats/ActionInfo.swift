/// A unit's current order, in OpenDUNE's `ActionType` order (`src/unit.h`).
public enum ActionType: Int, CaseIterable, Sendable {
    case attack = 0
    case move = 1
    case retreat = 2
    case guard_ = 3
    case areaGuard = 4
    case harvest = 5
    case `return` = 6
    case stop = 7
    case ambush = 8
    case sabotage = 9
    case die = 10
    case hunt = 11
    case deploy = 12
    case destruct = 13
}

/// The active input/selection mode, in OpenDUNE's `SelectionType` order (`src/gui/gui.h:21`). Referenced
/// by `ActionInfo.selectionType`; the broader UI uses the rest.
public enum SelectionType: Int, Sendable {
    case mentat = 0
    case target = 1
    case place = 2
    case unit = 3
    case structure = 4
    case debug = 5
    case unknown6 = 6
    case intro = 7
}

/// Per-action static stats. A literal port of OpenDUNE's `ActionInfo` struct (`src/unit.h`) and
/// `g_table_actionInfo[]` (`src/table/actioninfo.c`). Keyed by `ActionType`.
///
/// Verified field-for-field against an OpenDUNE golden dump — see `Documentation/Algorithms/StatTables.md`.
public struct ActionInfo: Sendable, Equatable {
    public let stringID: UInt16             // index into the string table (the action's display name)
    public let name: String
    public let switchType: UInt16           // 0 queue-if-needed, 1 change immediately, 2 via subroutine
    public let selectionType: SelectionType
    public let soundID: UInt16              // played for a Foot unit (0xFFFF = none)

    /// The four AI default-action choices, a port of OpenDUNE's `g_table_actionsAI[4]`
    /// (`src/table/unitinfo.c:12`): the actions an AI unit cycles through.
    public static let actionsAI: [ActionType] = [.hunt, .areaGuard, .ambush, .guard_]

    /// Stats for `action`.
    public static subscript(_ action: ActionType) -> ActionInfo { table[action.rawValue] }

    /// `g_table_actionInfo[]`, indexed by `ActionType.rawValue`. (`stringID` values are the resolved
    /// `STR_*` ids; `Stop`/`Deploy`/`Destruct` reuse general string ids 37/31/153.)
    public static let table: [ActionInfo] = [
        ActionInfo(stringID: 1, name: "Attack", switchType: 0, selectionType: .target, soundID: 21),
        ActionInfo(stringID: 2, name: "Move", switchType: 0, selectionType: .target, soundID: 22),
        ActionInfo(stringID: 3, name: "Retreat", switchType: 0, selectionType: .unit, soundID: 21),
        ActionInfo(stringID: 4, name: "Guard", switchType: 0, selectionType: .unit, soundID: 21),
        ActionInfo(stringID: 5, name: "Area Guard", switchType: 0, selectionType: .unit, soundID: 20),
        ActionInfo(stringID: 6, name: "Harvest", switchType: 0, selectionType: .target, soundID: 20),
        ActionInfo(stringID: 7, name: "Return", switchType: 0, selectionType: .unit, soundID: 21),
        ActionInfo(stringID: 37, name: "Stop", switchType: 0, selectionType: .unit, soundID: 21),
        ActionInfo(stringID: 9, name: "Ambush", switchType: 0, selectionType: .unit, soundID: 20),
        ActionInfo(stringID: 10, name: "Sabotage", switchType: 0, selectionType: .unit, soundID: 20),
        ActionInfo(stringID: 11, name: "Die", switchType: 1, selectionType: .unit, soundID: 0xFFFF),
        ActionInfo(stringID: 12, name: "Hunt", switchType: 0, selectionType: .unit, soundID: 20),
        ActionInfo(stringID: 31, name: "Deploy", switchType: 0, selectionType: .unit, soundID: 20),
        ActionInfo(stringID: 153, name: "Destruct", switchType: 1, selectionType: .unit, soundID: 20),
    ]
}
