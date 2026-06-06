import DuneIISimulation
import SwiftUI

/// Hosts the building context popover, anchored at the **clicked map point**. Filled over the map overlay
/// (`alignment: .topLeading`, the same coordinate space the right-click point is computed in); shows/hides off
/// `GameModel.buildingMenu`. The popover attaches via `attachmentAnchor: .point` (the click as a fraction of
/// the overlay size) so it emanates from the cursor — *not* from the window edge (a positioned 1pt anchor
/// makes the popover use the full overlay frame instead). Never eats map input.
public struct BuildingMenuAnchor: View {
    var model: GameModel

    public init(model: GameModel) { self.model = model }

    public var body: some View {
        GeometryReader { geo in
            Color.clear
                .popover(
                    isPresented: Binding(
                        get: { model.buildingMenu != nil },
                        set: { if !$0 { model.dismissBuildingMenu() } }
                    ),
                    attachmentAnchor: .point(anchor(in: geo.size)),
                    arrowEdge: .top
                ) {
                    if let menu = model.buildingMenu {
                        BuildingContextMenu(model: model, slot: menu.slot)
                            #if os(iOS)
                                // Keep it an anchored popover on iPhone (compact width defaults to a sheet).
                                .presentationCompactAdaptation(.popover)
                            #endif
                    }
                }
        }
        .allowsHitTesting(false)  // never intercept map clicks/pans
    }

    /// The click point as a `UnitPoint` (0…1) within the overlay, so the popover attaches at the cursor.
    private func anchor(in size: CGSize) -> UnitPoint {
        guard let p = model.buildingMenu?.point, size.width > 0, size.height > 0 else { return .center }

        return UnitPoint(x: p.x / size.width, y: p.y / size.height)
    }
}

/// The right-click building popup: the selected player structure's **state**, its **actions** (repair /
/// upgrade / super-weapon, or the in-progress build's pause/resume/place/stop), and its **build items** (the
/// factory/CY buildable list). A compact mirror of the sidebar's selection + build sections (the building is
/// also selected, so the sidebar shows the full controls — starport cart, requirement popovers, placement).
struct BuildingContextMenu: View {
    var model: GameModel
    let slot: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.selection, s.kind == .structure {
                header(s)
                actions
                buildItems
            } else {
                // The building was deselected / destroyed while open; clicking outside dismisses the popover.
                Text("—").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 240)
        .focusEffectDisabled()  // no focus rings on the popup's buttons/rows
    }

    @ViewBuilder private func header(_ s: SelectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.name).font(.headline)
            Text(s.state).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(s.hitpoints), total: Double(max(s.hitpointsMax, 1)))
                .tint(hpTint(s.hitpoints, s.hitpointsMax))
            Text("HP \(s.hitpoints) / \(s.hitpointsMax)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.structureActions != nil || model.superWeapon != nil {
            Divider()
            HStack(spacing: 0) {
                if let sa = model.structureActions {
                    ActionIcon(
                        systemImage: "wrench.and.screwdriver",
                        badge: "R",
                        active: sa.isRepairing,
                        help: sa.isRepairing ? "Stop repairing" : "Repair",
                        disabled: !sa.canRepair && !sa.isRepairing
                    ) { model.repairSelected() }
                    .frame(maxWidth: .infinity)
                    ActionIcon(
                        systemImage: "arrow.up.circle",
                        badge: "U",
                        active: sa.isUpgrading,
                        help: sa.isUpgrading ? "Stop upgrading" : "Upgrade",
                        disabled: !sa.canUpgrade && !sa.isUpgrading
                    ) { model.upgradeSelected() }
                    .frame(maxWidth: .infinity)
                }
                if let sw = model.superWeapon {
                    ActionIcon(
                        systemImage: sw.systemImage,
                        badge: "L",
                        active: model.missileTargeting != nil,
                        help: sw.ready ? sw.title : "Recharging…",
                        disabled: !sw.ready
                    ) {
                        model.launchSuperWeapon()
                        model.dismissBuildingMenu()  // close so a death-hand target click reaches the map
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var buildItems: some View {
        if model.isFactorySelected {
            Divider()
            if let bs = model.buildProgress {
                buildProgress(bs)
            } else if model.buildOptions.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.buildOptions, id: \.item.objectType) { option in
                            let item = option.item
                            let underfunded = option.isAvailable && item.cost > model.playerCredits
                            Button {
                                if option.isAvailable { model.startBuild(item.objectType) }
                            } label: {
                                HStack {
                                    Text(item.displayName).font(.caption)
                                    Spacer(minLength: 8)
                                    Text("\(item.cost)").font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(
                                    option.isAvailable ? (underfunded ? Color.orange : Color.primary) : Color.secondary
                                )
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Color.gray.opacity(option.isAvailable ? 0.2 : 0),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)  // .borderless draws an accent focus ring; .plain doesn't
                            .focusable(false)
                            .disabled(!option.isAvailable)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    @ViewBuilder private func buildProgress(_ bs: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bs.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
            ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
            HStack(spacing: 0) {
                if bs.isReady && bs.isStructure {
                    ActionIcon(systemImage: "mappin.and.ellipse", active: true, help: "Place") {
                        model.beginPlacement()
                        model.dismissBuildingMenu()  // close so the placement click reaches the map
                    }
                    .frame(maxWidth: .infinity)
                } else if bs.onHold {
                    ActionIcon(systemImage: "play.fill", active: true, help: "Resume") { model.resumeBuild() }
                        .frame(maxWidth: .infinity)
                } else if !bs.isReady {
                    ActionIcon(systemImage: "pause.fill", help: "Pause") { model.pauseBuild() }
                        .frame(maxWidth: .infinity)
                }
                ActionIcon(systemImage: "xmark", help: "Stop") { model.cancelBuild() }.frame(maxWidth: .infinity)
            }
        }
    }

    private func hpTint(_ hp: Int, _ maxHP: Int) -> Color {
        let f = maxHP > 0 ? Double(hp) / Double(maxHP) : 1
        return f > 0.66 ? .green : (f > 0.33 ? .yellow : .red)
    }
}
