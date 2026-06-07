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
    @State private var sprites = SpriteImageProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.selection, s.kind == .structure {
                // Identical to the sidebar's building display (same shared views); the popup only differs in
                // dismissing itself after actions whose next click must reach the map (place / super-weapon).
                SelectionTitle(model: model, info: s)
                HStack(spacing: 3) {
                    Spacer()
                    StructureActionBar(model: model, dismiss: model.dismissBuildingMenu)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        FactoryBuildList(model: model, sprites: sprites, dismiss: model.dismissBuildingMenu)
                        StarportOrderList(model: model, sprites: sprites)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                // The building was deselected / destroyed while open; clicking outside dismisses the popover.
                Text("—").foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(width: 240)
        .focusEffectDisabled()  // no focus rings on the popup's buttons/rows
    }
}
