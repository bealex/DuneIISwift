import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import SwiftUI

// MARK: - Shared building / selection controls
//
// The pieces below are rendered *identically* by the sidebar (`GameSidebar`, when an object is selected)
// and the right-click building popup (`BuildingContextMenu`). Keeping them in one place is what makes the
// popup "exactly the same" as the sidebar for buildings — by construction, not by hand-copying. The only
// per-host difference is `dismiss`: actions that need the next map click to land on the map (place a finished
// structure, fire a super-weapon) close the popup, but do nothing extra in the always-present sidebar.

/// HP-bar tint by remaining fraction.
func hpTint(_ hp: Int, _ maxHP: Int) -> Color {
    let f = maxHP > 0 ? Double(hp) / Double(maxHP) : 1
    return f > 0.66 ? .green : (f > 0.33 ? .yellow : .red)
}

/// The selected object's title — its name, an optional `×N` multi-select badge, and its HP bar.
struct SelectionTitle: View {
    var model: GameModel
    let info: SelectionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                // Baseline-align the ×N badge with the title text; full (un-minified) title line height.
                Text(info.name).font(.headline).lineLimit(2)
                if model.selectedUnitCount > 1 {
                    Text("×\(model.selectedUnitCount)").font(.caption.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                }
            }
            ProgressView(value: Double(info.hitpoints), total: Double(max(info.hitpointsMax, 1)))
                .tint(hpTint(info.hitpoints, info.hitpointsMax))
        }
    }
}

/// Repair / upgrade / super-weapon icons for a selected player structure. Renders nothing when the structure
/// has no actions. `dismiss` fires after launching the super-weapon (so the popup closes for the target click).
struct StructureActionBar: View {
    var model: GameModel
    var dismiss: () -> Void = {}

    var body: some View {
        if model.structureActions != nil || model.superWeapon != nil {
            HStack(spacing: 3) {
                if let sa = model.structureActions {
                    ActionIcon(
                        systemImage: "wrench.and.screwdriver",
                        badge: "R",
                        active: sa.isRepairing,
                        help: sa.isRepairing ? "Stop repairing (R)" : "Repair (R)",
                        disabled: !sa.canRepair && !sa.isRepairing
                    ) { model.repairSelected() }
                    // Hide Upgrade entirely when no upgrade is possible at this campaign level (vs. merely
                    // disabling it when it's possible but not actionable yet — e.g. the building needs repair).
                    if sa.upgradable {
                        ActionIcon(
                            systemImage: "arrow.up.circle",
                            badge: "U",
                            active: sa.isUpgrading,
                            help: sa.isUpgrading ? "Stop upgrading (U)" : "Upgrade (U)",
                            disabled: !sa.canUpgrade && !sa.isUpgrading
                        ) { model.upgradeSelected() }
                    }
                }
                if let sw = model.superWeapon {
                    ActionIcon(
                        systemImage: sw.systemImage,
                        badge: "L",
                        active: model.missileTargeting != nil,
                        help: sw.ready ? "\(sw.title) (L)" : "Recharging…",
                        disabled: !sw.ready
                    ) {
                        model.launchSuperWeapon()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// One buildable row: a fixed leading thumbnail, then the title (absorbing the slack) with an optional lock,
/// over the cost. Locked rows are greyed; underfunded costs go red.
struct BuildOptionRow: View {
    var model: GameModel
    var sprites: SpriteImageProvider
    let objectType: UInt16
    let isStructure: Bool
    let name: String
    let cost: Int
    let locked: Bool
    let underfunded: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A fixed, leading-pinned square so every row's thumbnail occupies identical space and the title
            // starts at the same x — the icon is left-aligned to the row, never centred in a wider column.
            SpriteThumbnail(
                objectType: objectType,
                isStructure: isStructure,
                house: model.playerHouse,
                height: 39,
                provider: sprites,
                assets: model.assets
            )
            .frame(width: 39, height: 39)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(locked ? 0.45 : 1)

            // The title absorbs the slack (maxWidth .infinity) so the lock + cost pin to the trailing edge —
            // every row is aligned on both the left (title) and right (cost) sides.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(name)
                        .font(.title3)
                        .lineLimit(1)
                        .foregroundStyle(locked ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(cost)").font(.caption.monospacedDigit())
                    .foregroundStyle(underfunded ? Color.red : Color.secondary)
            }
        }
    }
}

/// The in-progress build: the product thumbnail (with its place / resume / pause action overlaid) + name +
/// progress bar, and a stop button. `dismiss` fires after starting placement (so the popup closes for the
/// map click).
struct BuildProgressBar: View {
    var model: GameModel
    var sprites: SpriteImageProvider
    let bs: BuildState
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                SpriteThumbnail(
                    objectType: bs.objectType,
                    isStructure: bs.isStructure,
                    house: model.playerHouse,
                    height: 44,
                    provider: sprites,
                    assets: model.assets
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    if bs.isReady && bs.isStructure {
                        ActionIcon(systemImage: "mappin.and.ellipse", active: true, help: "Place") {
                            model.beginPlacement()
                            dismiss()
                        }
                        .foregroundStyle(.white)
                    } else if bs.onHold {
                        ActionIcon(systemImage: "play.fill", active: true, help: "Resume") { model.resumeBuild() }
                            .foregroundStyle(.white)
                    } else if !bs.isReady {
                        ActionIcon(systemImage: "pause.fill", help: "Pause") { model.pauseBuild() }
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(bs.displayName).font(.headline).lineLimit(1)
                        .multilineTextAlignment(.trailing)
                    ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
                }
                .frame(maxWidth: .infinity)

                ActionIcon(systemImage: "xmark", help: "Stop") { model.cancelBuild() }
            }
        }
    }
}

/// A selected factory/CY's build column: the in-progress build, or the buildable list (available items only),
/// or "nothing available". `dismiss` fires after starting placement of a finished structure.
struct FactoryBuildList: View {
    var model: GameModel
    var sprites: SpriteImageProvider
    var dismiss: () -> Void = {}
    /// The locked build row whose "what's needed" popover is open (by object type), or nil.
    @State private var requirementsFor: UInt16?

    var body: some View {
        if model.isFactorySelected {
            if let bs = model.buildProgress {
                Text("Building:").font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BuildProgressBar(model: model, sprites: sprites, bs: bs, dismiss: dismiss)
            } else if model.buildOptions.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Available to build:").font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 3) {
                    ForEach(model.buildOptions.filter { $0.isAvailable }, id: \.item.objectType) { option in
                        let item = option.item
                        let underfunded = option.isAvailable && item.cost > model.playerCredits

                        Button {
                            if option.isAvailable {
                                model.startBuild(item.objectType)
                            } else {
                                requirementsFor = item.objectType
                            }
                        } label: {
                            BuildOptionRow(
                                model: model,
                                sprites: sprites,
                                objectType: item.objectType,
                                isStructure: item.isStructure,
                                name: item.displayName,
                                cost: item.cost,
                                locked: !option.isAvailable,
                                underfunded: underfunded
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Color.gray.opacity(option.isAvailable ? 0.2 : 0),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)  // .borderless draws an accent focus ring in the popover; .plain doesn't
                        .focusable(false)
                        .frame(maxWidth: .infinity)
                        .help(buildHelp(option))
                        .popover(
                            isPresented: Binding(
                                get: { requirementsFor == item.objectType },
                                set: { if !$0 { requirementsFor = nil } }
                            ),
                            arrowEdge: .leading
                        ) {
                            RequirementsPopover(name: item.displayName, blockers: option.blockers)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The tooltip for a build button: what an item costs, and — when locked — what's missing to unlock it.
    private func buildHelp(_ option: BuildOption) -> String {
        let item = option.item
        if !option.isAvailable { return "Requires: " + option.blockers.map(\.summary).joined(separator: ", ") }
        if item.cost > model.playerCredits {
            return
                "Costs \(item.cost) cr — you have \(model.playerCredits); construction starts and pauses until you can pay."
        }
        return "Build \(item.displayName) (\(item.cost) cr)"
    }
}

/// A selected starport's CHOAM order column: the frigate-inbound countdown, the stock rows with −/＋ steppers,
/// and the staged-order total + Order / Clear buttons. Renders nothing for a non-starport.
struct StarportOrderList: View {
    var model: GameModel
    var sprites: SpriteImageProvider

    var body: some View {
        if model.isStarportSelected {
            Divider()
            Text("Order (Starport)").font(.headline)
            // A pending delivery: the frigate-arrival countdown (the original shows this only as the frigate
            // flying in; we add a progress bar so the wait is legible).
            if let d = model.starportDelivery {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Frigate inbound…", systemImage: "airplane.arrival")
                        .font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value: d.fraction).tint(.yellow)
                }
            }
            if model.starportStock.isEmpty {
                Text("No CHOAM stock.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 3) {
                    ForEach(model.starportStock, id: \.objectType) { item in starportRow(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The staged order: total + Order / Cancel (charged only on Order).
                if model.cartUnitCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(model.cartUnitCount)×").font(.caption.bold().monospacedDigit())
                        Spacer(minLength: 0)
                        Text("\(model.cartTotalCost) cr").font(.caption.monospacedDigit())
                            .foregroundStyle(model.cartTotalCost > model.playerCredits ? Color.red : .secondary)
                    }
                    .padding(.top, 2)
                    HStack(spacing: 6) {
                        Button {
                            model.sendStarportOrder()
                        } label: {
                            Label("Order", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cartTotalCost > model.playerCredits)
                        Button(role: .destructive) {
                            model.clearStarportCart()
                        } label: {
                            Label("Clear", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// One CHOAM order line: the unit thumbnail + name, its stock and price, and a −/＋ stepper that stages
    /// the unit in the order cart. Greyed when sold out; the ＋ disables at the stock limit or when the running
    /// cart total would exceed the player's credits.
    @ViewBuilder private func starportRow(_ item: StarportItem) -> some View {
        let count = model.cartCount(item.objectType)
        HStack(spacing: 6) {
            SpriteThumbnail(
                objectType: item.objectType,
                isStructure: false,
                house: model.playerHouse,
                height: 24,
                provider: sprites,
                assets: model.assets
            )
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(item.soldOut ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName).font(.caption).lineLimit(1)
                    .foregroundStyle(item.soldOut ? .secondary : .primary)
                HStack(spacing: 3) {
                    Text(item.soldOut ? "Sold out" : "\(item.available) left")
                        .foregroundStyle(item.soldOut ? Color.red : .secondary)
                    if !item.soldOut {
                        Text("· \(item.cost)")
                            .foregroundStyle(item.cost > model.playerCredits ? Color.red : .secondary)
                    }
                }
                .font(.system(size: 9)).monospacedDigit()
            }
            Spacer(minLength: 0)
            if count > 0 {
                stepButton("minus") { model.cartRemove(item.objectType) }
                Text("\(count)").font(.caption.monospacedDigit().bold()).frame(minWidth: 12)
            }
            stepButton("plus", disabled: !model.canAddToCart(item)) { model.cartAdd(item.objectType) }
        }
    }

    private func stepButton(
        _ systemImage: String,
        disabled: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).disabled(disabled)
    }
}
