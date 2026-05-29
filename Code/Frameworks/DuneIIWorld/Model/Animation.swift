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

/// An active animation instance. A port of OpenDUNE's `Animation` (`src/animation.c`); lives in the
/// `GameState.animations` pool. `tableIndex` is the row of `AnimationTables.structure` it runs
/// (`active == false` means a free slot).
public struct Animation: Sendable, Equatable {
    public var tickNext: UInt32 = 0
    public var tileLayout: UInt16 = 0
    public var houseID: UInt8 = 0
    public var current: UInt8 = 0          // cursor into the command list
    public var iconGroup: UInt8 = 0
    public var tableIndex: Int = -1        // row in AnimationTables.structure
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
}
