import DuneIIFormats
import Foundation

/// Reads an **original** Dune II / OpenDUNE savegame (the IFF/FORM `.SAV`) and converts its *semantic* state
/// into one of our `GameState`s. Per the plan (`Plan.v1.md` §2), this is **not** a byte-for-byte EMC-VM
/// resume: we read the map seed + houses + units + structures + scenario tallies and instantiate our model
/// (re-generating the landscape from the seed, then applying the saved tile overrides). A converted game
/// continues *behaviorally* faithfully (a harvesting unit keeps harvesting) but not bit-identically to how
/// OpenDUNE would have continued that exact save — unlike our own `SaveGame`, which does resume bit-exactly.
///
/// Container: a big-endian IFF `FORM` with a `SCEN` marker then little-endian chunks — `NAME`, `INFO`
/// (scenario + globals), `PLYR` (houses), `UNIT`, `BLDG` (structures), `MAP ` (sparse tile overrides),
/// `TEAM`, `ODUN` (OpenDUNE's extended unit fields). The per-record field layouts are ports of OpenDUNE's
/// `SaveLoadDesc` lists (`src/save_load/`). See `Documentation/Formats/Save.md`.
public enum SaveConverter {
    public enum ConvertError: Error, Equatable { case notForm, truncated, badChunk }

    // On-disk record sizes (a Dune2 `Object` embeds a 55-byte `ScriptEngine`; we skip the script and re-seed).
    private static let scriptEngineSize = 55
    private static let objectSize = 16 + scriptEngineSize           // 71
    private static let unitSize = objectSize + 57                   // 128
    private static let structureSize = objectSize + 17             // 88
    private static let houseSize = 66
    private static let infoSize = 2 + 228 + 100                     // version + g_scenario + globals = 330

    /// Convert an original `.SAV` into a `GameState`. `iconMap` (the install's `ICON.MAP`) drives the
    /// seed-regenerated landscape + tile ids; the result mirrors a freshly `loadScenario`'d state (scripts are
    /// left unloaded — the caller does the scenario-prep `setAction`, exactly as for an `.INI` load).
    public static func convert(_ data: Data, iconMap: IconMap) throws -> GameState {
        var r = Reader(data)
        guard r.remaining >= 12, r.tag() == "FORM" else { throw ConvertError.notForm }
        _ = r.u32be()                                  // FORM length (we read to the chunks' own lengths)
        guard r.tag() == "SCEN" else { throw ConvertError.notForm }

        // Collect the chunks (tag → byte range).
        var chunks: [String: (start: Int, len: Int)] = [:]
        while r.remaining >= 8 {
            let tag = r.tag()
            let len = Int(r.u32be())
            guard r.pos + len <= r.bytes.count else { throw ConvertError.truncated }
            chunks[tag] = (r.pos, len)
            r.skip(len + (len & 1))                    // chunks pad to an even length
        }

        var state = GameState()
        state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        state.iconMap = iconMap

        // INFO — scenario + the globals we resume (seed/scale drive the map; campaign/credits/score the rest).
        guard let info = chunks["INFO"], info.len >= infoSize else { throw ConvertError.badChunk }
        let mapSeed = readInfo(Reader(data, info.start), into: &state)

        // Regenerate the landscape from the seed, then apply the MAP chunk's sparse tile overrides.
        state.createLandscape(seed: mapSeed, iconMap: iconMap)
        if let map = chunks["MAP "] { applyMap(Reader(data, map.start, map.len), into: &state) }

        // Bypass placement/count validation while repopulating the pools from the save (the loader path does
        // the same), then restore it. Houses are applied LAST: `unitAllocate` bumps `houses[].unitCount`, so
        // overwriting each house with its saved record afterwards restores the exact saved counts.
        state.validateStrictIfZero = 1
        if let bldg = chunks["BLDG"] { readStructures(Reader(data, bldg.start, bldg.len), into: &state) }
        if let unit = chunks["UNIT"] { readUnits(Reader(data, unit.start, unit.len), into: &state) }
        if let plyr = chunks["PLYR"] { readHouses(Reader(data, plyr.start, plyr.len), into: &state) }
        state.validateStrictIfZero = 0

        // The player is the human-controlled house (`g_playerHouseID = h->index` for `flags.human`).
        if let player = state.houses.first(where: { $0.flags.contains(.used) && $0.flags.contains(.human) }) {
            state.playerHouseID = player.index
        }
        return state
    }

    // MARK: - INFO (scenario + globals)

    private static func readInfo(_ r0: Reader, into state: inout GameState) -> UInt32 {
        var r = r0
        _ = r.u16()   // save version (e.g. 0x0290) — we read the semantic state, not version-specific layout
        var s = Scenario()
        s.score = r.u16(); s.winFlags = r.u16(); s.loseFlags = r.u16()
        let mapSeed = r.u32()
        let mapScale = r.u16()
        _ = r.u16()                                    // timeOut
        r.skip(14 + 14 + 14)                           // pictureBriefing/Win/Lose
        s.killedAllied = r.u16(); s.killedEnemy = r.u16()
        s.destroyedAllied = r.u16(); s.destroyedEnemy = r.u16()
        s.harvestedAllied = UInt32(r.u16()); s.harvestedEnemy = UInt32(r.u16())
        r.skip(16 * 10)                                // reinforcement[16] (recipe re-derivation is a seam)

        // Globals (after g_scenario).
        state.playerCreditsNoSilo = r.u16()
        state.minimapPosition = r.u16(); state.viewportPosition = state.minimapPosition
        _ = r.u16()                                    // selectionRectanglePosition
        _ = r.i8()                                     // selectionType
        _ = r.i8()                                     // structureActiveType (int8 on disk)
        _ = r.u16()                                    // structureActivePosition
        _ = r.u16(); _ = r.u16(); _ = r.u16()          // structureActive / unitSelected / unitActive
        _ = r.u16()                                    // activeAction
        _ = r.u32()                                    // strategicRegionBits
        _ = r.u16()                                    // scenarioID
        state.campaignID = UInt8(truncatingIfNeeded: r.u16())
        _ = r.u32(); _ = r.u32()                       // hintsShown1/2
        state.tickScenarioStart = r.u32()
        _ = r.u16()                                    // playerCreditsNoSilo (duplicate)
        for i in 0 ..< 27 where i < state.starportAvailable.count { state.starportAvailable[i] = r.i16() }

        state.scenario = s
        state.mapScale = UInt8(truncatingIfNeeded: mapScale)
        return mapSeed
    }

    // MARK: - MAP (sparse tile overrides)

    private static func applyMap(_ r0: Reader, into state: inout GameState) {
        var r = r0
        while r.remaining >= 6 {
            let idx = Int(r.u16())
            let b0 = r.u8(), b1 = r.u8(), b2 = r.u8(), b3 = r.u8()
            guard idx < state.map.count else { continue }
            state.map[idx].groundTileID = UInt16(b0) | (UInt16(b1 & 1) << 8)
            state.map[idx].overlayTileID = b1 >> 1
            state.map[idx].houseID = b2 & 0x7
            state.map[idx].isUnveiled = (b2 >> 3) & 1 != 0
            state.map[idx].hasUnit = (b2 >> 4) & 1 != 0
            state.map[idx].hasStructure = (b2 >> 5) & 1 != 0
            state.map[idx].hasAnimation = (b2 >> 6) & 1 != 0
            state.map[idx].hasExplosion = (b2 >> 7) & 1 != 0
            state.map[idx].index = b3
        }
    }

    // MARK: - Object base (shared by Unit + Structure)

    private static func readObject(_ r: inout Reader) -> Object {
        var o = Object()
        o.index = r.u16()
        o.type = r.u8()
        o.linkedID = r.u8()
        o.flags = ObjectFlags(rawValue: r.u32())
        o.houseID = r.u8()
        o.seenByHouses = r.u8()
        o.position = Tile32(x: r.u16(), y: r.u16())
        o.hitpoints = r.u16()
        r.skip(scriptEngineSize)   // the EMC script state — re-seeded on resume, not converted
        return o
    }

    // MARK: - PLYR (houses)

    private static func readHouses(_ r0: Reader, into state: inout GameState) {
        var r = r0
        while r.remaining >= houseSize {
            var h = House()
            h.index = UInt8(truncatingIfNeeded: r.u16())
            h.harvestersIncoming = r.u16()
            h.flags = HouseFlags(rawValue: UInt8(truncatingIfNeeded: r.u16()))
            h.unitCount = r.u16(); h.unitCountMax = r.u16(); h.unitCountEnemy = r.u16(); h.unitCountAllied = r.u16()
            h.structuresBuilt = r.u32()
            h.credits = r.u16(); h.creditsStorage = r.u16()
            h.powerProduction = r.u16(); h.powerUsage = r.u16()
            h.windtrapCount = r.u16(); h.creditsQuota = r.u16()
            h.palacePosition = Tile32(x: r.u16(), y: r.u16())
            _ = r.u16()   // padding
            h.timerUnitAttack = r.u16(); h.timerSandwormAttack = r.u16(); h.timerStructureAttack = r.u16()
            h.starportTimeLeft = r.u16(); h.starportLinkedID = r.u16()
            for i in 0 ..< 5 { h.aiStructureRebuild[i] = [r.u16(), r.u16()] }
            guard h.index < UInt8(state.houses.count), state.houseAllocate(index: h.index) != nil else { continue }
            state.houses[Int(h.index)] = h
        }
    }

    // MARK: - BLDG (structures)

    private static func readStructures(_ r0: Reader, into state: inout GameState) {
        var r = r0
        while r.remaining >= structureSize {
            var s = Structure()
            s.o = readObject(&r)
            s.creatorHouseID = r.u16()
            s.rotationSpriteDiff = r.u16()
            _ = r.u8()   // padding
            s.objectType = r.u16()
            s.upgradeLevel = r.u8(); s.upgradeTimeLeft = r.u8()
            s.countDown = r.u16(); s.buildCostRemainder = r.u16()
            s.state = StructureState(rawValue: r.i16()) ?? .idle
            s.hitpointsMax = r.u16()
            guard let slot = state.structureAllocate(index: s.o.index, type: s.o.type) else { continue }
            state.structures[slot] = s
        }
    }

    // MARK: - UNIT (units)

    private static func readUnits(_ r0: Reader, into state: inout GameState) {
        var r = r0
        while r.remaining >= unitSize {
            var u = Unit()
            u.o = readObject(&r)
            _ = r.u16()   // padding
            u.currentDestination = Tile32(x: r.u16(), y: r.u16())
            u.originEncoded = r.u16()
            u.actionID = r.u8(); u.nextActionID = r.u8()
            u.fireDelay = UInt16(r.u8())   // u8 on disk
            u.distanceToDestination = r.u16()
            u.targetAttack = r.u16(); u.targetMove = r.u16()
            u.amount = r.u8(); u.deviated = r.u8()
            u.targetLast = Tile32(x: r.u16(), y: r.u16())
            u.targetPreLast = Tile32(x: r.u16(), y: r.u16())
            for i in 0 ..< 2 {
                var d = Dir24(); d.speed = r.i8(); d.target = r.i8(); d.current = r.i8(); u.orientation[i] = d
            }
            u.speedPerTick = r.u8(); u.speedRemainder = r.u8(); u.speed = r.u8(); u.movingSpeed = r.u8()
            u.wobbleIndex = r.u8(); u.spriteOffset = r.i8(); u.blinkCounter = r.u8(); u.team = r.u8()
            u.timer = r.u16()
            for i in 0 ..< 14 { u.route[i] = r.u8() }
            guard state.unitAllocate(index: u.o.index, type: u.o.type, houseID: u.o.houseID) != nil else { continue }
            state.units[Int(u.o.index)] = u
        }
    }

    /// A little cursor over the save bytes — little-endian for fields, big-endian for the IFF container.
    private struct Reader {
        let bytes: [UInt8]
        var pos: Int
        let end: Int
        init(_ data: Data) { bytes = [UInt8](data); pos = 0; end = bytes.count }
        init(_ data: Data, _ start: Int, _ len: Int? = nil) {
            bytes = [UInt8](data); pos = start; end = len.map { start + $0 } ?? bytes.count
        }
        var remaining: Int { end - pos }
        mutating func u8() -> UInt8 { defer { pos += 1 }; return bytes[pos] }
        mutating func i8() -> Int8 { Int8(bitPattern: u8()) }
        mutating func u16() -> UInt16 { let lo = UInt16(u8()); return lo | (UInt16(u8()) << 8) }
        mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
        mutating func u32() -> UInt32 {
            let a = UInt32(u8()), b = UInt32(u8()), c = UInt32(u8()), d = UInt32(u8())
            return a | (b << 8) | (c << 16) | (d << 24)
        }
        mutating func u32be() -> UInt32 {
            let a = UInt32(u8()), b = UInt32(u8()), c = UInt32(u8()), d = UInt32(u8())
            return (a << 24) | (b << 16) | (c << 8) | d
        }
        mutating func tag() -> String { defer { pos += 4 }; return String(bytes: bytes[pos ..< pos + 4], encoding: .ascii) ?? "" }
        mutating func skip(_ n: Int) { pos += n }
    }
}
