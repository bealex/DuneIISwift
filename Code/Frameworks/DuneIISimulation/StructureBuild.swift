import DuneIIContracts
import DuneIIWorld

/// One thing a factory can produce right now — a unit (unit factory) or a structure (construction yard).
/// `objectType` is the `UnitType.rawValue` / `StructureType.rawValue` to pass to `Command.build`.
public struct Buildable: Sendable, Equatable {
    public let objectType: UInt16
    public let isStructure: Bool
    public let cost: Int
    public let buildTime: Int

    public init(objectType: UInt16, isStructure: Bool, cost: Int, buildTime: Int) {
        self.objectType = objectType
        self.isStructure = isStructure
        self.cost = cost
        self.buildTime = buildTime
    }

    /// The product's display name (`UnitType`/`StructureType` `displayName`).
    public var displayName: String { Self.name(objectType: objectType, isStructure: isStructure) }

    static func name(objectType: UInt16, isStructure: Bool) -> String {
        if isStructure { return StructureType(rawValue: Int(objectType))?.displayName ?? "?" }
        return UnitType(rawValue: Int(objectType))?.displayName ?? "?"
    }
}

/// A factory's in-progress build, for the build-progress UI.
public struct BuildState: Sendable, Equatable {
    public let objectType: UInt16
    public let isStructure: Bool
    /// 0…1 — `1 - countDown / (buildTime << 8)`.
    public let progress: Double
    public let isReady: Bool
    public let onHold: Bool

    public init(objectType: UInt16, isStructure: Bool, progress: Double, isReady: Bool, onHold: Bool) {
        self.objectType = objectType
        self.isStructure = isStructure
        self.progress = progress
        self.isReady = isReady
        self.onHold = onHold
    }

    /// The product's display name (`UnitType`/`StructureType` `displayName`).
    public var displayName: String { Buildable.name(objectType: objectType, isStructure: isStructure) }
}

/// A single reason a `BuildOption` can't be built yet (credits are excluded — the UI checks those live, as
/// they change every tick). Mirrors the gating in `Structure_GetBuildable` (`structure.c:1834`).
public enum BuildBlocker: Sendable, Equatable {
    /// The active campaign (mission) level is below the item's threshold (construction-yard structures only —
    /// units have no campaign gate). `level` is the minimum `campaignID` that unlocks it.
    case campaign(level: Int)
    /// A prerequisite structure the house hasn't built yet.
    case structure(StructureType)
    /// The factory must be upgraded to at least this level first.
    case upgradeLevel(Int)

    /// A short human label for the build tooltip.
    public var summary: String {
        switch self {
            case .campaign(let level): "Campaign \(level)"
            case .structure(let type): type.displayName
            case .upgradeLevel(let level): "Factory upgrade \(level)"
        }
    }
}

/// One row of a factory's **full** build menu: the item plus, when not currently buildable, the reasons why.
/// Unlike `buildables` (which returns only the ready-now items), `buildOptions` lists every item the house
/// could ever build at this factory (so the GUI can show locked items greyed-out with a "what's missing"
/// tooltip). `blockers` empty ⇔ buildable now (credits aside).
public struct BuildOption: Sendable, Equatable {
    public let item: Buildable
    public let blockers: [BuildBlocker]

    public init(item: Buildable, blockers: [BuildBlocker]) {
        self.item = item
        self.blockers = blockers
    }

    /// Buildable right now (ignoring credits)?
    public var isAvailable: Bool { blockers.isEmpty }

    /// Locked because the active campaign (mission) level is below the item's threshold. The original game
    /// doesn't list such items at all — they only appear once the campaign reaches their tier — so the GUI
    /// hides these rather than greying them out (a prerequisite/upgrade lock is achievable this mission and
    /// stays visible). True iff any blocker is a `.campaign` gate.
    public var isCampaignGated: Bool {
        blockers.contains { if case .campaign = $0 { true } else { false } }
    }
}

/// The build-GUI queries the simulation needs (read-only, no mutation): what a factory can build, how a
/// build is progressing, and whether a placement tile is valid. See `Documentation/Architecture/BuildGUI.md`.
public extension Simulation {
    /// `Structure_GetBuildable` (`structure.c:1834`): the items factory `slot` can currently produce,
    /// filtered by the house's built structures, the item's `structuresRequired`/`availableHouse`/
    /// `availableCampaign`, the active `campaignID`, and the factory's `upgradeLevel`. Unit factories list
    /// units; the construction yard lists structures. Upgrade-first items (`available == -1`) are omitted.
    func buildables(forStructure slot: Int) -> [Buildable] {
        guard
            slot >= 0,
            slot < state.structures.count,
            let st = StructureType(rawValue: Int(state.structures[slot].o.type))
        else { return [] }
        let s = state.structures[slot]
        let structuresBuilt = state.houses[Int(s.o.houseID)].structuresBuilt
        let player = state.playerHouseID
        let campaign = UInt16(state.campaignID)
        let ordos = UInt16(HouseID.ordos.rawValue)
        let harkonnen = UInt8(HouseID.harkonnen.rawValue)
        var result: [Buildable] = []

        switch st {
            case .lightVehicle, .heavyVehicle, .highTech, .worTrooper, .barracks:
                for raw in StructureInfo[st].buildableUnits where raw != 0xFF {
                    var unitRaw = raw
                    if unitRaw == UInt8(UnitType.trike.rawValue) && s.creatorHouseID == ordos {
                        unitRaw = UInt8(UnitType.raiderTrike.rawValue)
                    }
                    guard let ut = UnitType(rawValue: Int(unitRaw)) else { continue }
                    let ui = UnitInfo[ut].o
                    var upgradeRequired = UInt16(ui.upgradeLevelRequired)
                    if ut == .siegeTank && s.creatorHouseID == ordos { upgradeRequired &-= 1 }
                    if (structuresBuilt & ui.structuresRequired) != ui.structuresRequired { continue }
                    if (ui.availableHouse & (1 << s.creatorHouseID)) == 0 { continue }
                    if UInt16(s.upgradeLevel) >= upgradeRequired {
                        result.append(
                            Buildable(
                                objectType: UInt16(ut.rawValue),
                                isStructure: false,
                                cost: Int(ui.buildCredits),
                                buildTime: Int(ui.buildTime)
                            )
                        )
                    }
                }

            case .constructionYard:
                for i in 0 ..< StructureType.allCases.count {
                    guard let stType = StructureType(rawValue: i) else { continue }
                    let lsi = StructureInfo[stType].o
                    var availableCampaign = lsi.availableCampaign
                    var structuresRequired = lsi.structuresRequired
                    if stType == .worTrooper && s.o.houseID == harkonnen && state.campaignID >= 1 {
                        structuresRequired &= ~(UInt32(1) << StructureType.barracks.rawValue)
                        availableCampaign = 2
                    }
                    guard
                        (structuresBuilt & structuresRequired) == structuresRequired || s.o.houseID != player
                    else {
                        continue
                    }
                    if s.o.houseID != harkonnen && stType == .lightVehicle { availableCampaign = 2 }
                    guard
                        campaign >= availableCampaign &- 1,
                        (lsi.availableHouse & (1 << s.o.houseID)) != 0
                    else {
                        continue
                    }
                    if UInt16(s.upgradeLevel) >= UInt16(lsi.upgradeLevelRequired) || s.o.houseID != player {
                        result.append(
                            Buildable(
                                objectType: UInt16(i),
                                isStructure: true,
                                cost: Int(lsi.buildCredits),
                                buildTime: Int(lsi.buildTime)
                            )
                        )
                    }
                }

            default: break
        }
        return result
    }

    /// The factory's **full** build menu: every item this house could ever build here, each tagged with the
    /// reasons it isn't buildable yet (empty `blockers` ⇒ ready now). The available subset (`isAvailable`) is
    /// exactly what `buildables(forStructure:)` returns — this function adds the locked items + their blockers
    /// for the greyed-out GUI listing. Same gating as `Structure_GetBuildable` (`structure.c:1834`); items the
    /// house can't build at all (`availableHouse`) and the construction-yard self-entry (`FLAG_STRUCTURE_NEVER`)
    /// are excluded. Intended for a player-owned factory (no AI/non-player prerequisite bypass).
    func buildOptions(forStructure slot: Int) -> [BuildOption] {
        guard
            slot >= 0,
            slot < state.structures.count,
            let st = StructureType(rawValue: Int(state.structures[slot].o.type))
        else { return [] }
        let s = state.structures[slot]
        let structuresBuilt = state.houses[Int(s.o.houseID)].structuresBuilt
        let campaign = UInt16(state.campaignID)
        let ordos = UInt16(HouseID.ordos.rawValue)
        let harkonnen = UInt8(HouseID.harkonnen.rawValue)
        var result: [BuildOption] = []

        switch st {
            case .lightVehicle, .heavyVehicle, .highTech, .worTrooper, .barracks:
                for raw in StructureInfo[st].buildableUnits where raw != 0xFF {
                    var unitRaw = raw
                    if unitRaw == UInt8(UnitType.trike.rawValue) && s.creatorHouseID == ordos {
                        unitRaw = UInt8(UnitType.raiderTrike.rawValue)
                    }
                    guard let ut = UnitType(rawValue: Int(unitRaw)) else { continue }
                    let ui = UnitInfo[ut].o
                    if (ui.availableHouse & (1 << s.creatorHouseID)) == 0 { continue }
                    var upgradeRequired = UInt16(ui.upgradeLevelRequired)
                    if ut == .siegeTank && s.creatorHouseID == ordos { upgradeRequired &-= 1 }
                    var blockers = Self.missingStructureBlockers(
                        required: ui.structuresRequired,
                        built: structuresBuilt
                    )
                    if UInt16(s.upgradeLevel) < upgradeRequired { blockers.append(.upgradeLevel(Int(upgradeRequired))) }
                    result.append(
                        BuildOption(
                            item: Buildable(
                                objectType: UInt16(ut.rawValue),
                                isStructure: false,
                                cost: Int(ui.buildCredits),
                                buildTime: Int(ui.buildTime)
                            ),
                            blockers: blockers
                        )
                    )
                }

            case .constructionYard:
                for i in 0 ..< StructureType.allCases.count {
                    guard let stType = StructureType(rawValue: i) else { continue }
                    let lsi = StructureInfo[stType].o
                    // The construction yard itself (FLAG_STRUCTURE_NEVER) is never a build item.
                    if lsi.structuresRequired == 0xFFFF_FFFF { continue }
                    if (lsi.availableHouse & (1 << s.o.houseID)) == 0 { continue }
                    var availableCampaign = lsi.availableCampaign
                    var structuresRequired = lsi.structuresRequired
                    if stType == .worTrooper && s.o.houseID == harkonnen && state.campaignID >= 1 {
                        structuresRequired &= ~(UInt32(1) << StructureType.barracks.rawValue)
                        availableCampaign = 2
                    }
                    if s.o.houseID != harkonnen && stType == .lightVehicle { availableCampaign = 2 }
                    var blockers = Self.missingStructureBlockers(required: structuresRequired, built: structuresBuilt)
                    if campaign < availableCampaign &- 1 {
                        blockers.append(.campaign(level: Int(availableCampaign) - 1))
                    }
                    if UInt16(s.upgradeLevel) < UInt16(lsi.upgradeLevelRequired) {
                        blockers.append(.upgradeLevel(Int(lsi.upgradeLevelRequired)))
                    }
                    result.append(
                        BuildOption(
                            item: Buildable(
                                objectType: UInt16(i),
                                isStructure: true,
                                cost: Int(lsi.buildCredits),
                                buildTime: Int(lsi.buildTime)
                            ),
                            blockers: blockers
                        )
                    )
                }

            default: break
        }
        return result
    }

    /// The prerequisite structures in `required` the house hasn't `built` yet, as `.structure` blockers.
    static func missingStructureBlockers(required: UInt32, built: UInt32) -> [BuildBlocker] {
        let missing = required & ~built
        guard missing != 0 else { return [] }
        var out: [BuildBlocker] = []
        for i in 0 ..< StructureType.allCases.count where (missing & (UInt32(1) << i)) != 0 {
            if let t = StructureType(rawValue: i) { out.append(.structure(t)) }
        }
        return out
    }

    /// Factory `slot`'s in-progress build, or `nil` when it isn't building (no linked product).
    func buildState(structureSlot slot: Int) -> BuildState? {
        guard slot >= 0, slot < state.structures.count else { return nil }
        let s = state.structures[slot]
        guard
            let st = StructureType(rawValue: Int(s.o.type)),
            StructureInfo[st].o.flags.contains(.factory),
            s.o.linkedID != 0xFF,
            s.objectType != 0xFFFF
        else { return nil }
        let isStructure = (st == .constructionYard)
        let buildTime: Int = isStructure
            ? StructureType(rawValue: Int(s.objectType)).map { Int(StructureInfo[$0].o.buildTime) } ?? 0
            : UnitType(rawValue: Int(s.objectType)).map { Int(UnitInfo[$0].o.buildTime) } ?? 0
        let total = buildTime << 8
        let progress = total > 0 ? 1 - Double(s.countDown) / Double(total) : (s.state == .ready ? 1 : 0)
        return BuildState(
            objectType: s.objectType,
            isStructure: isStructure,
            progress: min(1, max(0, progress)),
            isReady: s.state == .ready,
            onHold: s.o.flags.contains(.onHold)
        )
    }

    /// `Structure_IsValidBuildLocation` (`structure.c:734`) for the placement preview: ≥1 = valid (all on
    /// slab), 0 = blocked, <0 = buildable but missing |n| slabs (a later HP penalty). `nil` if no combat
    /// layer (no `UNIT.EMC` bridged).
    func placementValidity(type: StructureType, tile: UInt16) -> Int16? {
        guard let combat = unitScript?.combat else { return nil }
        return combat.structureIsValidBuildLocation(tile, type: type, in: state)
    }
}
