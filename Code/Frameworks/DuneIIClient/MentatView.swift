import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import SwiftUI

/// The Mentat advisor — a browsable help database. The topic list (Structures / Vehicles / Special / Houses)
/// and every description are loaded from the player house's `MENTAT<HOUSE>.ENG` (`MentatHelp`), filtered to
/// what's unlocked at the scenario's campaign level. Each topic shows the original description text alongside
/// the unit/building sprite and key stats from our tables. Replaces the old single-object info card.
struct MentatView: View {
    @State
    var model: GameModel
    let provider: SpriteImageProvider
    @State
    private var selected: String?

    nonisolated private static let sectionOrder: [MentatHelp.Section] = [
        .structures, .vehicles, .specials, .houses,
    ]

    /// What a Mentat topic refers to, for the sprite + stat lookup (houses / lore have none).
    private enum Subject { case structure(StructureType), unit(UnitType), none }

    private var topics: [MentatHelp.Topic] {
        let letter = Character(model.playerHouse.displayName.prefix(1).uppercased())
        // The Mentat is a full reference: list *every* unit/building topic, not only those unlocked at the
        // current campaign level. (The original gates the list by `campaign`; we show all so nothing is left
        // undescribed.) Section headers and the general Advice/Orders entries are still dropped.
        return model.assets.mentatTopics(houseLetter: letter)
            .filter { !$0.isHeader && $0.section != .general }
    }

    var body: some View {
        HStack(spacing: 0) {
            topicList
            Divider()
            detail
        }
        #if os(iOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
            .gamePopover(width: 760, maxHeight: 520)
        #endif
        .onAppear { if selected == nil { selected = initialSelection } }
    }

    // MARK: Master list

    private var topicList: some View {
        List(selection: $selected) {
            ForEach(Self.sectioned(topics)) { group in
                Section(sectionTitle(group.section)) {
                    ForEach(group.items, id: \.name) { topic in
                        HStack(spacing: 7) {
                            thumbnail(topic, size: 20)
                            Text(topic.name).font(.callout).lineLimit(1)
                        }
                        .tag(topic.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 252)  // 20% wider than the old 210
    }

    /// One sidebar section with its topics. `id` is the section so `ForEach` can iterate the groups.
    struct TopicGroup: Identifiable {
        let section: MentatHelp.Section
        let items: [MentatHelp.Topic]
        var id: MentatHelp.Section { section }
    }

    /// Group the topics into the fixed section order, each section's entries **sorted by name** (natural,
    /// case-insensitive). Pure + testable; empty sections are dropped.
    nonisolated static func sectioned(_ topics: [MentatHelp.Topic]) -> [TopicGroup] {
        sectionOrder.compactMap { section in
            let items =
                topics
                .filter { $0.section == section }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return items.isEmpty ? nil : TopicGroup(section: section, items: items)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let name = selected, let topic = topics.first(where: { $0.name == name }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        // The original Mentat picture — framed by width with its true height (it isn't square),
                        // so its top aligns with the title beside it.
                        detailImage(topic, width: 256)
                        // Title + stats to the right of the image.
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(heading(topic)).font(.title2.bold())
                                ForEach(subheadings(topic), id: \.self) { line in
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            statsGrid(topic)
                            requirementsBlock(topic)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    // Description under the image and stats, full width.
                    if !topic.body.isEmpty {
                        Divider()
                        Text(topic.body).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Mentat",
                systemImage: "brain.head.profile",
                description: Text("Pick a topic to read about it.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// The detail heading. For **houses** the parsed description `title` is a lead-in line that varies by the
    /// player's own mentat file — e.g. for Atreides it's the planet ("Caladan:", "Name: Unknown"), not the
    /// house — so it reads as a "strange title". Use the canonical topic name there instead; for buildings/units
    /// the `title` matches the name and is kept.
    private func heading(_ topic: MentatHelp.Topic) -> String {
        if topic.section == .houses { return topic.name }
        return topic.title.isEmpty ? topic.name : topic.title
    }

    /// The grey sub-lines under the heading: a house's **home planet** (the original game only fills this in
    /// the Atreides mentat file's title, e.g. "Caladan:"; we show it for every house from whichever house's
    /// mentat is loaded), otherwise the topic's attribute lines (unit/structure stat blurbs).
    private func subheadings(_ topic: MentatHelp.Topic) -> [String] {
        if topic.section == .houses {
            if let planet = Self.homePlanet(forHouseTopic: topic.name) { return [ "Home planet: \(planet)" ] }
            return (!topic.title.isEmpty && topic.title != topic.name) ? [ topic.title ] : []
        }
        return topic.attributes
    }

    /// Each playable house's home planet, for the houses-section subtitle. Ordos's homeworld is canonically
    /// unrecorded (the Atreides mentat itself reads "Name: Unknown"). `nil` for any non-house topic.
    nonisolated static func homePlanet(forHouseTopic name: String) -> String? {
        if name.contains("Atreides") { return "Caladan" }
        if name.contains("Harkonnen") { return "Giedi Prime" }
        if name.contains("Ordos") { return "Unknown" }
        return nil
    }

    /// Cost / HP / power (structures) or cost / HP / damage / range (units), from our stat tables.
    @ViewBuilder private func statsGrid(_ topic: MentatHelp.Topic) -> some View {
        switch subject(topic.name) {
            case let .structure(t):
                let si = StructureInfo[t]
                let power = Int(si.powerUsage)
                HStack(spacing: 16) {
                    stat("Cost", "\(si.o.buildCredits)")
                    stat("Armor", "\(si.o.hitpoints)")
                    if power != 0 { stat(power < 0 ? "Power +" : "Power −", "\(abs(power))") }
                }
            case let .unit(t):
                let ui = UnitInfo[t]
                HStack(spacing: 16) {
                    if ui.o.buildCredits > 0 { stat("Cost", "\(ui.o.buildCredits)") }
                    stat("Armor", "\(ui.o.hitpoints)")
                    if ui.damage > 0 { stat("Damage", "\(ui.damage)") }
                    if ui.fireDistance > 0 { stat("Range", "\(ui.fireDistance)") }
                }
            case .none:
                EmptyView()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
    }

    /// The build prerequisites for the topic (prerequisite buildings + the required Construction-Yard / factory
    /// upgrade level), shown for the player's house. Hidden for items with no prerequisites and lore topics.
    @ViewBuilder private func requirementsBlock(_ topic: MentatHelp.Topic) -> some View {
        let reqs = Self.requirements(for: topic.name, house: model.playerHouse)
        if !reqs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("Requires").font(.caption2).foregroundStyle(.secondary)
                Text(reqs.joined(separator: ", "))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The build prerequisites for a Mentat topic, in words: the prerequisite buildings (decoded from the
    /// item's `structuresRequired` bitmask) plus the builder's required upgrade level. Mirrors
    /// `Structure_GetBuildable`'s gating, including the player-house special cases (Harkonnen WOR needs no
    /// Barracks; the Ordos Siege Tank needs one upgrade level fewer). Empty for the Construction Yard
    /// (`FLAG_STRUCTURE_NEVER`), prerequisite-free items, and house/lore topics. Pure + testable.
    nonisolated static func requirements(for name: String, house: HouseID) -> [String] {
        let required: UInt32
        var upgrade: Int
        let builder: String
        if let t = structures[name] {
            var req = StructureInfo[t].o.structuresRequired
            if t == .worTrooper, house == .harkonnen {  // Harkonnen WOR drops the Barracks prerequisite.
                req &= ~(UInt32(1) << StructureType.barracks.rawValue)
            }
            required = req
            upgrade = Int(StructureInfo[t].o.upgradeLevelRequired)
            builder = StructureType.constructionYard.displayName
        } else if let t = units[name] {
            required = UnitInfo[t].o.structuresRequired
            upgrade = Int(UnitInfo[t].o.upgradeLevelRequired)
            if t == .siegeTank, house == .ordos { upgrade -= 1 }  // Ordos gets the Siege Tank a level early.
            builder = "Factory"
        } else {
            return []
        }
        guard required != 0xFFFF_FFFF else { return [] }  // Construction Yard: never a build prerequisite list.

        var reqs: [String] = []
        for i in 0 ..< StructureType.allCases.count where (required & (UInt32(1) << i)) != 0 {
            if let s = StructureType(rawValue: i) { reqs.append(s.displayName) }
        }
        if upgrade > 0 { reqs.append("\(builder) upgrade ×\(upgrade)") }
        return reqs
    }

    // MARK: Picture

    /// Each topic's icon is the original Mentat picture — the `*.WSA` named in its description (`MENTAT.PAK`),
    /// the same image `GUI_Mentat_Loop` shows — not our composed game sprite. Whole-picture scaled to fit the
    /// box (buildings are wider than tall). Falls back to a sprite/symbol only if the WSA is missing.
    @ViewBuilder private func thumbnail(_ topic: MentatHelp.Topic, size: CGFloat) -> some View {
        if !topic.wsa.isEmpty, let picture = provider.wsaImage(name: topic.wsa, assets: model.assets) {
            Image(decorative: picture, scale: 1).interpolation(.none).resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            spriteFallback(topic, size: size)
        }
    }

    /// The large detail picture, framed by **width** at the image's natural height. The Mentat WSA pictures
    /// aren't square (buildings are wider than tall), so the old fixed square box `.fit`-letterboxed them —
    /// centring the image vertically while the title started at the box top, leaving the two misaligned.
    /// Sizing the box to the real picture lines its top up with the title. Falls back to a square sprite.
    @ViewBuilder private func detailImage(_ topic: MentatHelp.Topic, width: CGFloat) -> some View {
        if !topic.wsa.isEmpty, let picture = provider.wsaImage(name: topic.wsa, assets: model.assets) {
            let ratio = Self.imageAspectRatio(width: picture.width, height: picture.height)
            Image(decorative: picture, scale: 1).interpolation(.none).resizable()
                .frame(width: width, height: width / ratio)
        } else {
            spriteFallback(topic, size: width)
        }
    }

    /// A picture's width÷height aspect ratio, guarding a zero height (→ 1, a square). Pure + testable.
    nonisolated static func imageAspectRatio(width: Int, height: Int) -> CGFloat {
        height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }

    @ViewBuilder private func spriteFallback(_ topic: MentatHelp.Topic, size: CGFloat) -> some View {
        switch subject(topic.name) {
            case let .structure(t):
                SpriteThumbnail(
                    objectType: UInt16(t.rawValue),
                    isStructure: true,
                    house: model.playerHouse,
                    height: size,
                    provider: provider,
                    assets: model.assets
                )
                .frame(width: size, height: size)
            case let .unit(t):
                SpriteThumbnail(
                    objectType: UInt16(t.rawValue),
                    isStructure: false,
                    house: model.playerHouse,
                    height: size,
                    provider: provider,
                    assets: model.assets
                )
                .frame(width: size, height: size)
            case .none:
                Image(systemName: topic.section == .houses ? "flag.fill" : "sparkles")
                    .font(.system(size: size * 0.6)).foregroundStyle(.secondary)
                    .frame(width: size, height: size)
        }
    }

    // MARK: Topic → type mapping

    private func sectionTitle(_ s: MentatHelp.Section) -> String {
        switch s {
            case .structures: "Structures";
            case .vehicles: "Vehicles"
            case .specials: "Special";
            case .houses: "Houses";
            case .general: ""
        }
    }

    /// Map a MENTAT topic name to the structure/unit it describes (for the sprite + stats). Names differ from
    /// our display names, so the mapping is explicit.
    private func subject(_ name: String) -> Subject {
        if let s = Self.structures[name] { return .structure(s) }
        if let u = Self.units[name] { return .unit(u) }
        return .none
    }

    // Topic names vary slightly between the per-house Mentat files (e.g. "Wind Trap" vs "Windtrap",
    // "Deviator" vs "Ordos Deviator"), so every spelling is mapped to keep the sprite + stats panel populated.
    nonisolated private static let structures: [String: StructureType] = [
        "Barracks": .barracks, "Concrete Slab": .slab1x1, "Construction Yard": .constructionYard,
        "Heavy Factory": .heavyVehicle, "High-Tech Factory": .highTech, "IX": .houseOfIx,
        "Light Factory": .lightVehicle, "Outpost": .outpost, "Palace": .palace, "Refinery": .refinery,
        "Repair Facility": .repair, "Rocket Turret": .rocketTurret, "Spice Silos": .silo,
        "Starport": .starport, "Turret": .turret, "Wall": .wall,
        "Windtrap": .windtrap, "Wind Trap": .windtrap, "Wor": .worTrooper,
    ]
    nonisolated private static let units: [String: UnitType] = [
        "Carryall": .carryall, "Combat Tank": .tank, "Harvester": .harvester, "Heavy Troopers": .troopers,
        "Light Infantry": .infantry, "MCV": .mcv, "Ordos Raider": .raiderTrike, "Ornithopter": .ornithopter,
        "Quad": .quad, "Rocket Tank": .launcher, "Siege Tank": .siegeTank, "Trike": .trike,
        "Devastator": .devastator, "Deviator": .deviator, "Ordos Deviator": .deviator,
        "Saboteur": .saboteur, "Sand Worm": .sandworm, "Sonic Tank": .sonicTank,
    ]

    /// Open on the selected unit/building's topic when there is one, else the first topic.
    private var initialSelection: String? {
        if let sel = model.selection {
            let match = topics.first { topic in
                return switch subject(topic.name) {
                    case let .structure(t): sel.kind == .structure && UInt16(t.rawValue) == sel.typeRaw
                    case let .unit(t): sel.kind == .unit && UInt16(t.rawValue) == sel.typeRaw
                    case .none: false
                }
            }
            if let match { return match.name }
        }
        return topics.first?.name
    }
}
