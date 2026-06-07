import DuneIIContracts
import Testing

@testable import DuneIIClient
@testable import DuneIIFormats

/// The Mentat help page's two presentation seams: the per-topic **build requirements** line
/// (`MentatView.requirements`) and the **name-sorted** sidebar grouping (`MentatView.sectioned`). Pure logic
/// over the static stat tables — no install needed. (This is a UI/presentation seam with no OpenDUNE oracle,
/// so unit coverage is the bar; the engine's `Structure_GetBuildable` gating is itself golden-tested.)
struct MentatHelpInfoTests {
    // MARK: requirements

    /// The Rocket Turret — the case that prompted this: it needs Windtrap + Radar Outpost **and** the
    /// Construction Yard upgraded twice (its `upgradeLevelRequired == 2`).
    @Test func rocketTurretRequirementsSpellOutTheUpgrade() {
        let reqs = MentatView.requirements(for: "Rocket Turret", house: .atreides)
        #expect(reqs == [ "Windtrap", "Outpost", "Construction Yard upgrade ×2" ])
    }

    /// A factory lists its prerequisite buildings in bit order, no upgrade clause when none is needed.
    @Test func heavyFactoryListsItsPrerequisites() {
        #expect(
            MentatView.requirements(for: "Heavy Factory", house: .atreides)
                == [ "Light Factory", "Windtrap", "Outpost" ]
        )
    }

    /// The Construction Yard (`FLAG_STRUCTURE_NEVER`), prerequisite-free buildings, and lore topics show none.
    @Test func itemsWithoutPrerequisitesHaveNoRequirements() {
        #expect(MentatView.requirements(for: "Construction Yard", house: .atreides).isEmpty)
        #expect(MentatView.requirements(for: "Windtrap", house: .atreides).isEmpty)
        #expect(MentatView.requirements(for: "Wind Trap", house: .atreides).isEmpty)  // alt spelling
        #expect(MentatView.requirements(for: "Atreides", house: .atreides).isEmpty)  // a house/lore topic
    }

    /// Player-house special cases mirror `Structure_GetBuildable`: Harkonnen WOR drops the Barracks
    /// prerequisite; the Ordos Siege Tank needs one upgrade level fewer.
    @Test func houseSpecialCasesMatchTheBuildGating() {
        // WOR: Windtrap + Barracks + Outpost for Ordos; Harkonnen drops the Barracks.
        #expect(MentatView.requirements(for: "Wor", house: .ordos) == [ "Windtrap", "Barracks", "Outpost" ])
        #expect(MentatView.requirements(for: "Wor", house: .harkonnen) == [ "Windtrap", "Outpost" ])
        // Siege Tank: a Heavy-Factory upgrade, one level cheaper for Ordos.
        #expect(MentatView.requirements(for: "Siege Tank", house: .atreides) == [ "Factory upgrade ×3" ])
        #expect(MentatView.requirements(for: "Siege Tank", house: .ordos) == [ "Factory upgrade ×2" ])
    }

    // MARK: sectioned (sidebar order)

    private func topic(_ name: String, _ section: MentatHelp.Section) -> MentatHelp.Topic {
        MentatHelp.Topic(
            section: section,
            isHeader: false,
            name: name,
            campaign: 1,
            wsa: "",
            title: name,
            attributes: [],
            body: ""
        )
    }

    @Test func sidebarSortsEachSectionByNameInTheFixedSectionOrder() {
        let topics = [
            topic("Windtrap", .structures), topic("Barracks", .structures), topic("Refinery", .structures),
            topic("Trike", .vehicles), topic("Carryall", .vehicles),
            topic("Saboteur", .specials),
        ]
        let groups = MentatView.sectioned(topics)
        // Sections in the fixed order (structures, vehicles, specials, houses); empty ones dropped.
        #expect(groups.map(\.section) == [ .structures, .vehicles, .specials ])
        // Each section's entries sorted by name.
        #expect(groups[0].items.map(\.name) == [ "Barracks", "Refinery", "Windtrap" ])
        #expect(groups[1].items.map(\.name) == [ "Carryall", "Trike" ])
        #expect(groups[2].items.map(\.name) == [ "Saboteur" ])
    }
}
