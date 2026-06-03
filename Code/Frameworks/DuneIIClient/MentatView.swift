import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import SwiftUI

/// The Mentat advisor — a browsable help database. The topic list (Structures / Vehicles / Special / Houses)
/// and every description are loaded from the player house's `MENTAT<HOUSE>.ENG` (`MentatHelp`), filtered to
/// what's unlocked at the scenario's campaign level. Each topic shows the original description text alongside
/// the unit/building sprite and key stats from our tables. Replaces the old single-object info card.
struct MentatView: View {
    @State var model: GameModel
    let provider: SpriteImageProvider
    @State private var selected: String?

    private static let sectionOrder: [MentatHelp.Section] = [ .structures, .vehicles, .specials, .houses ]

    /// What a Mentat topic refers to, for the sprite + stat lookup (houses / lore have none).
    private enum Subject { case structure(StructureType), unit(UnitType), none }

    private var topics: [MentatHelp.Topic] {
        let letter = Character(model.playerHouse.displayName.prefix(1).uppercased())
        return model.assets.mentatTopics(houseLetter: letter)
            .filter { !$0.isHeader && $0.section != .general && $0.campaign <= model.campaignLevel + 1 }
    }

    var body: some View {
        HStack(spacing: 0) {
            topicList
            Divider()
            detail
        }
        .frame(width: 580, height: 460)
        .onAppear { if selected == nil { selected = initialSelection } }
    }

    // MARK: Master list

    private var topicList: some View {
        List(selection: $selected) {
            ForEach(Self.sectionOrder, id: \.self) { section in
                let items = topics.filter { $0.section == section }
                if !items.isEmpty {
                    Section(sectionTitle(section)) {
                        ForEach(items, id: \.name) { topic in
                            HStack(spacing: 7) {
                                thumbnail(topic, size: 20)
                                Text(topic.name).font(.callout).lineLimit(1)
                            }
                            .tag(topic.name)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 210)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let name = selected, let topic = topics.first(where: { $0.name == name }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        thumbnail(topic, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.title.isEmpty ? topic.name : topic.title).font(.title2.bold())
                            ForEach(topic.attributes, id: \.self) { attr in
                                Text(attr).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    statsGrid(topic)
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

    // MARK: Sprite

    @ViewBuilder private func thumbnail(_ topic: MentatHelp.Topic, size: CGFloat) -> some View {
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

    private static let structures: [String: StructureType] = [
        "Barracks": .barracks, "Concrete Slab": .slab1x1, "Construction Yard": .constructionYard,
        "Heavy Factory": .heavyVehicle, "High-Tech Factory": .highTech, "IX": .houseOfIx,
        "Light Factory": .lightVehicle, "Outpost": .outpost, "Palace": .palace, "Refinery": .refinery,
        "Repair Facility": .repair, "Rocket Turret": .rocketTurret, "Spice Silos": .silo,
        "Starport": .starport, "Turret": .turret, "Wall": .wall, "Windtrap": .windtrap, "Wor": .worTrooper,
    ]
    private static let units: [String: UnitType] = [
        "Carryall": .carryall, "Combat Tank": .tank, "Harvester": .harvester, "Heavy Troopers": .troopers,
        "Light Infantry": .infantry, "MCV": .mcv, "Ordos Raider": .raiderTrike, "Ornithopter": .ornithopter,
        "Quad": .quad, "Rocket Tank": .launcher, "Siege Tank": .siegeTank, "Trike": .trike,
        "Devastator": .devastator, "Ordos Deviator": .deviator, "Saboteur": .saboteur,
        "Sand Worm": .sandworm, "Sonic Tank": .sonicTank,
    ]

    /// Open on the selected unit/building's topic when there is one, else the first topic.
    private var initialSelection: String? {
        if let sel = model.selection {
            let match = topics.first { topic in
                switch subject(topic.name) {
                    case let .structure(t): return sel.kind == .structure && UInt16(t.rawValue) == sel.typeRaw
                    case let .unit(t): return sel.kind == .unit && UInt16(t.rawValue) == sel.typeRaw
                    case .none: return false
                }
            }
            if let match { return match.name }
        }
        return topics.first?.name
    }
}
