/// A single animation command. A port of OpenDUNE's `AnimationCommand` (`src/animation.h`).
public enum AnimationCommand: UInt8, Sendable, Equatable {
    case stop = 0            // gracefully stop + clean up the tiles
    case abort = 1           // stop, leaving the tiles as they are
    case setOverlayTile = 2  // param: new overlay tile (icon-group offset)
    case pause = 3           // param: ticks to pause (+ 0…3 random jitter)
    case rewind = 4          // restart the command list
    case playVoice = 5       // param: voice id (no-op headless)
    case setGroundTile = 6   // param: icon-group state to stamp into the layout's ground tiles
    case forward = 7         // param: relative command jump (param − 1 added to the cursor)
    case setIconGroup = 8    // param: new icon group
}

/// One `(command, parameter)` step. A port of `AnimationCommandStruct` (`src/animation.h`).
public struct AnimationCommandStruct: Sendable, Equatable {
    public let command: AnimationCommand
    public let parameter: Int16
    public init(_ command: AnimationCommand, _ parameter: Int16) { self.command = command; self.parameter = parameter }
}

private func cmd(_ command: AnimationCommand, _ parameter: Int16) -> AnimationCommandStruct {
    AnimationCommandStruct(command, parameter)
}

/// Which command table an animation runs: a structure's ground-cycle (`g_table_animation_structure`) or a
/// dead unit's corpse overlay (`g_table_animation_unitScript1` for 3-frame infantry, `…unitScript2` else).
public enum AnimationKind: UInt8, Sendable, Equatable {
    case structure, unitScript1, unitScript2
}

/// An active animation instance. A port of OpenDUNE's `Animation` (`src/animation.c`); lives in the
/// `GameState.animations` pool. `tableIndex` is the row of the `kind`'s command table it runs
/// (`active == false` means a free slot).
public struct Animation: Sendable, Equatable {
    public var tickNext: UInt32 = 0
    public var tileLayout: UInt16 = 0
    public var houseID: UInt8 = 0
    public var current: UInt8 = 0          // cursor into the command list
    public var iconGroup: UInt8 = 0
    public var tableIndex: Int = -1        // row in the `kind`'s command table
    public var kind: AnimationKind = .structure
    public var tile: Tile32 = Tile32(x: 0, y: 0)
    public var active = false
    public init() {}
}

/// The animation command tables. `structure` is a port of `g_table_animation_structure` (29 rows),
/// generated from the OpenDUNE oracle dump (`animationstructure-golden.jsonl`) and golden-checked.
public enum AnimationTables {
    public static let structure: [[AnimationCommandStruct]] = [
        [ cmd(.setGroundTile, 1), cmd(.pause, 300), cmd(.abort, 0) ],
        [ cmd(.setGroundTile, 0), cmd(.abort, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 300), cmd(.abort, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 6), cmd(.pause, 30), cmd(.setGroundTile, 7), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 8), cmd(.pause, 30), cmd(.setGroundTile, 9), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 7), cmd(.pause, 30), cmd(.setGroundTile, 6), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 6), cmd(.pause, 30), cmd(.setGroundTile, 7), cmd(.pause, 30), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 6), cmd(.pause, 30), cmd(.setGroundTile, 7), cmd(.pause, 30), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 4), cmd(.pause, 30), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 5), cmd(.pause, 30), cmd(.setGroundTile, 6), cmd(.pause, 30), cmd(.setGroundTile, 7), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 8), cmd(.pause, 30), cmd(.setGroundTile, 9), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 8), cmd(.pause, 60), cmd(.setGroundTile, 9), cmd(.pause, 60), cmd(.setGroundTile, 6), cmd(.pause, 60), cmd(.setGroundTile, 5), cmd(.pause, 60), cmd(.setGroundTile, 2), cmd(.pause, 60), cmd(.setGroundTile, 3), cmd(.pause, 60), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 60), cmd(.setGroundTile, 3), cmd(.pause, 60), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 60), cmd(.setGroundTile, 5), cmd(.pause, 60), cmd(.setGroundTile, 6), cmd(.pause, 60), cmd(.setGroundTile, 9), cmd(.pause, 60), cmd(.setGroundTile, 8), cmd(.pause, 60), cmd(.forward, -4) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
        [ cmd(.setGroundTile, 2), cmd(.pause, 30), cmd(.setGroundTile, 3), cmd(.pause, 30), cmd(.rewind, 0) ],
    ]

    /// `g_table_animation_unitScript1[4]` (`table/animation.c:66`) — the corpse overlay for a 3-frame
    /// infantry unit (soldier/trooper). Rows 0/1 = on sand, 2/3 = on rock (`variables[1] == 1` adds 2).
    public static let unitScript1: [[AnimationCommandStruct]] = [
        [ cmd(.setOverlayTile, 0), cmd(.pause, 600), cmd(.setOverlayTile, 1), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 0), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 4), cmd(.playVoice, 35), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 5), cmd(.playVoice, 35), cmd(.pause, 600), cmd(.stop, 0) ],
    ]

    /// `g_table_animation_unitScript2[4]` (`table/animation.c:93`) — the corpse overlay for the other foot
    /// units (4-frame infantry/troopers).
    public static let unitScript2: [[AnimationCommandStruct]] = [
        [ cmd(.setOverlayTile, 2), cmd(.pause, 600), cmd(.setOverlayTile, 3), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 2), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 4), cmd(.playVoice, 35), cmd(.pause, 600), cmd(.stop, 0) ],
        [ cmd(.setOverlayTile, 5), cmd(.playVoice, 35), cmd(.pause, 600), cmd(.stop, 0) ],
    ]
}
