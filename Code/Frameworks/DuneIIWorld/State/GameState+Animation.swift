import DuneIIContracts

/// The structure-animation engine — a faithful port of OpenDUNE's `src/animation.c` (+ the
/// `Structure_UpdateMap` hookup, `src/structure.c`). Animations mutate the map's ground tiles over
/// time (cycling a building's icon-group states), driven by `animationTick()` from the game loop.
/// Overlay/fog and the render dirty-marking are not modelled here (the viewer draws ground tiles).
public extension GameState {
    /// `Structure_UpdateMap`: stamp a placed structure's built (state 2) tiles into the map and start
    /// its idle animation (per `StructureInfo.animationIndex[state]`; `0xFF` = no animation).
    mutating func structureUpdateMap(_ index: Int) {
        let s = structures[index]
        guard s.o.flags.contains(.used), !s.o.flags.contains(.isNotOnMap),
              let type = StructureType(rawValue: Int(s.o.type)), let iconMap else { return }
        let si = StructureInfo[type]
        let layout = StructureLayoutInfo[si.layout]
        let count = Int(layout.tileCount)
        let packed = Int(s.o.position.packed)

        for i in 0 ..< count {
            let pos = packed + Int(layout.tiles[i])
            guard pos >= 0, pos < map.count else { continue }
            let tile = UInt16(iconMap.tileID(group: Int(si.iconGroup), offset: count * 2 + i) ?? 0)
            map[pos].houseID = s.o.houseID
            map[pos].hasStructure = true
            map[pos].index = UInt8(truncatingIfNeeded: index + 1)
            map[pos].groundTileID = tile &+ s.rotationSpriteDiff
        }
        mapDirty = true

        let layoutRaw = UInt16(si.layout.rawValue)
        let iconGroup = UInt8(truncatingIfNeeded: Int(si.iconGroup))
        if s.state.rawValue >= StructureState.idle.rawValue {
            let stateIndex = min(Int(s.state.rawValue), Int(StructureState.ready.rawValue))
            let animID = Int(si.animationIndex[stateIndex])
            if animID == 0xFF {
                map[packed].hasAnimation = true            // Animation_Start(NULL): static, no slot
                map[packed].houseID = s.o.houseID
            } else {
                animationStart(tableIndex: animID, tile: s.o.position, tileLayout: layoutRaw,
                               houseID: s.o.houseID, iconGroup: iconGroup)
            }
        } else {
            animationStart(tableIndex: 1, tile: s.o.position, tileLayout: layoutRaw,
                           houseID: s.o.houseID, iconGroup: iconGroup)
        }
    }

    /// `Animation_Start`. `kind` selects the command table (structure ground-cycle by default; a unit
    /// corpse-overlay table for `Script_Unit_StartAnimation`).
    mutating func animationStart(tableIndex: Int, tile: Tile32, tileLayout: UInt16, houseID: UInt8,
                                 iconGroup: UInt8, kind: AnimationKind = .structure) {
        animationStopByTile(tile.packed)
        let packed = Int(tile.packed)
        for i in animations.indices where !animations[i].active {
            var a = Animation()
            a.tickNext = timerGUI
            a.tileLayout = tileLayout
            a.houseID = houseID
            a.iconGroup = iconGroup
            a.tableIndex = tableIndex
            a.kind = kind
            a.tile = tile
            a.active = true
            animations[i] = a
            animationTimer = 0
            map[packed].houseID = houseID
            map[packed].hasAnimation = true
            return
        }
    }

    /// `Animation_Stop_ByTile`.
    mutating func animationStopByTile(_ packed: UInt16) {
        guard map[Int(packed)].hasAnimation else { return }
        for i in animations.indices where animations[i].active && animations[i].tile.packed == packed {
            animationStop(i)
            return
        }
    }

    /// `Animation_Tick`: process every active animation whose next-tick has arrived.
    mutating func animationTick() {
        if animationTimer > timerGUI { return }
        animationTimer = animationTimer &+ 10000

        for i in animations.indices where animations[i].active {
            if animations[i].tickNext <= timerGUI {
                let table: [[AnimationCommandStruct]]
                switch animations[i].kind {
                    case .structure:   table = AnimationTables.structure
                    case .unitScript1: table = AnimationTables.unitScript1
                    case .unitScript2: table = AnimationTables.unitScript2
                    case .unitMove:    table = AnimationTables.unitMove
                    case .map:         table = AnimationTables.map
                }
                let row = table[animations[i].tableIndex]
                let cursor = Int(animations[i].current)
                guard cursor < row.count else { animationStop(i); continue }
                let command = row[cursor]
                animations[i].current = animations[i].current &+ 1

                switch command.command {
                    case .stop: animationStop(i)
                    case .abort: animationAbort(i)
                    case .setOverlayTile: animationSetOverlayTile(i, command.parameter)
                    case .pause: animations[i].tickNext = timerGUI &+ UInt32(max(0, Int(command.parameter))) &+ UInt32(random256.next() % 4)
                    case .rewind: animations[i].current = 0
                    case .playVoice: emitSound(Int(command.parameter), at: animations[i].tile)   // Animation_Func_PlayVoice
                    case .setGroundTile: animationSetGroundTile(i, command.parameter)
                    case .forward: animations[i].current = UInt8(truncatingIfNeeded: Int(animations[i].current) + Int(command.parameter) - 1)
                    case .setIconGroup: animations[i].iconGroup = UInt8(truncatingIfNeeded: command.parameter)
                }
                if !animations[i].active { continue }
            }
            if animations[i].tickNext < animationTimer { animationTimer = animations[i].tickNext }
        }
    }

    // MARK: - Command handlers

    private mutating func animationStop(_ i: Int) {
        let a = animations[i]
        let layout = StructureLayoutInfo[StructureLayout(rawValue: Int(a.tileLayout)) ?? .layout1x1]
        let packed = Int(a.tile.packed)
        map[packed].hasAnimation = false
        animations[i].active = false
        for k in 0 ..< Int(layout.tileCount) {
            let pos = packed + Int(layout.tiles[k])
            guard pos >= 0, pos < map.count else { continue }
            if a.tileLayout != 0 { map[pos].groundTileID = mapBaseTileID[pos] }
            // Clear a corpse/overlay the animation laid down (`Animation_Func_Stop`, only on revealed tiles).
            if map[pos].isUnveiled { map[pos].overlayTileID = 0 }
        }
        mapDirty = true
    }

    /// `Animation_Func_SetOverlayTile`: stamp the animation's overlay sprite (e.g. a unit corpse) onto its
    /// tile, from `iconGroup` + `parameter`. Only on a revealed tile (the renderer composites the overlay).
    private mutating func animationSetOverlayTile(_ i: Int, _ parameter: Int16) {
        guard let iconMap, parameter >= 0 else { return }
        let a = animations[i]
        let packed = Int(a.tile.packed)
        guard map[packed].isUnveiled else { return }
        let tile = iconMap.tileID(group: Int(a.iconGroup), offset: Int(parameter)) ?? 0
        map[packed].overlayTileID = UInt8(truncatingIfNeeded: tile)
        map[packed].houseID = a.houseID
        mapDirty = true
    }

    private mutating func animationAbort(_ i: Int) {
        map[Int(animations[i].tile.packed)].hasAnimation = false
        animations[i].active = false
    }

    private mutating func animationSetGroundTile(_ i: Int, _ parameter: Int16) {
        guard let iconMap else { return }
        let a = animations[i]
        let layout = StructureLayoutInfo[StructureLayout(rawValue: Int(a.tileLayout)) ?? .layout1x1]
        let count = Int(layout.tileCount)
        let packed = Int(a.tile.packed)
        for k in 0 ..< count {
            let pos = packed + Int(layout.tiles[k])
            guard pos >= 0, pos < map.count else { continue }
            let tile = UInt16(iconMap.tileID(group: Int(a.iconGroup), offset: count * Int(parameter) + k) ?? 0)
            if map[pos].groundTileID == tile { continue }
            map[pos].groundTileID = tile
            map[pos].houseID = a.houseID
            mapDirty = true
        }
    }
}
