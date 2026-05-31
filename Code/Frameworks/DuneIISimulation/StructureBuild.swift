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

/// The build-GUI queries the simulation needs (read-only, no mutation): what a factory can build, how a
/// build is progressing, and whether a placement tile is valid. See `Documentation/Architecture/BuildGUI.md`.
public extension Simulation {
    /// `Structure_GetBuildable` (`structure.c:1834`): the items factory `slot` can currently produce,
    /// filtered by the house's built structures, the item's `structuresRequired`/`availableHouse`/
    /// `availableCampaign`, the active `campaignID`, and the factory's `upgradeLevel`. Unit factories list
    /// units; the construction yard lists structures. Upgrade-first items (`available == -1`) are omitted.
    func buildables(forStructure slot: Int) -> [Buildable] {
        guard slot >= 0, slot < state.structures.count,
              let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return [] }
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
                        result.append(Buildable(objectType: UInt16(ut.rawValue), isStructure: false,
                                                cost: Int(ui.buildCredits), buildTime: Int(ui.buildTime)))
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
                    guard (structuresBuilt & structuresRequired) == structuresRequired || s.o.houseID != player else { continue }
                    if s.o.houseID != harkonnen && stType == .lightVehicle { availableCampaign = 2 }
                    guard campaign >= availableCampaign &- 1, (lsi.availableHouse & (1 << s.o.houseID)) != 0 else { continue }
                    if UInt16(s.upgradeLevel) >= UInt16(lsi.upgradeLevelRequired) || s.o.houseID != player {
                        result.append(Buildable(objectType: UInt16(i), isStructure: true,
                                                cost: Int(lsi.buildCredits), buildTime: Int(lsi.buildTime)))
                    }
                }

            default: break
        }
        return result
    }

    /// Factory `slot`'s in-progress build, or `nil` when it isn't building (no linked product).
    func buildState(structureSlot slot: Int) -> BuildState? {
        guard slot >= 0, slot < state.structures.count else { return nil }
        let s = state.structures[slot]
        guard let st = StructureType(rawValue: Int(s.o.type)), StructureInfo[st].o.flags.contains(.factory),
              s.o.linkedID != 0xFF, s.objectType != 0xFFFF else { return nil }
        let isStructure = (st == .constructionYard)
        let buildTime: Int = isStructure
            ? StructureType(rawValue: Int(s.objectType)).map { Int(StructureInfo[$0].o.buildTime) } ?? 0
            : UnitType(rawValue: Int(s.objectType)).map { Int(UnitInfo[$0].o.buildTime) } ?? 0
        let total = buildTime << 8
        let progress = total > 0 ? 1 - Double(s.countDown) / Double(total) : (s.state == .ready ? 1 : 0)
        return BuildState(objectType: s.objectType, isStructure: isStructure,
                          progress: min(1, max(0, progress)), isReady: s.state == .ready,
                          onHold: s.o.flags.contains(.onHold))
    }

    /// `Structure_IsValidBuildLocation` (`structure.c:734`) for the placement preview: ≥1 = valid (all on
    /// slab), 0 = blocked, <0 = buildable but missing |n| slabs (a later HP penalty). `nil` if no combat
    /// layer (no `UNIT.EMC` bridged).
    func placementValidity(type: StructureType, tile: UInt16) -> Int16? {
        guard let combat = unitScript?.combat else { return nil }
        return combat.structureIsValidBuildLocation(tile, type: type, in: state)
    }
}
