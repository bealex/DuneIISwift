import SwiftUI

/// The floating game-control cluster overlaid on the **top-right** of the map — Mentat, Options, Save, Load
/// (moved off the sidebar's old bottom button row). Mirrors `MapStatsOverlay`'s top-corner placement, but is
/// interactive. Options + Mentat present as a macOS popover / an iOS full-screen cover (the same split the
/// sidebar used) and freeze the game while open (balanced `beginUIPause`/`endUIPause`). Save/Load are
/// platform-specific (macOS `NSSavePanel` ↔ iOS Documents quicksave), so the app shell injects them.
public struct MapControlsOverlay: View {
    var model: GameModel
    let onSave: () -> Void
    let onLoad: () -> Void

    // Mentat needs an image provider; this cluster owns its own (the sidebar keeps a separate one for its
    // selection/build thumbnails — a sprite cache, cheap to have twice).
    @State
    private var sprites = SpriteImageProvider()
    @State
    private var showOptions = false
    @State
    private var showMentat = false

    public init(model: GameModel, onSave: @escaping () -> Void, onLoad: @escaping () -> Void) {
        self.model = model
        self.onSave = onSave
        self.onLoad = onLoad
    }

    public var body: some View {
        HStack(spacing: 8) {
            controlButton("brain.head.profile", help: "Mentat — buildings, units, and house info") {
                showMentat = true
            }
            controlButton("gearshape.fill", help: "Options") { showOptions = true }
                // iOS: full-screen (a popover is too cramped for the scenario picker + speed + debug toggles).
                // macOS: a popover dropping down from the top-right button (`.bottom` arrow edge).
                #if os(iOS)
                    .fullScreenCover(isPresented: $showOptions) {
                        OptionsPopover(model: model, isPresented: $showOptions)
                    }
                #else
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        OptionsPopover(model: model, isPresented: $showOptions)
                    }
                #endif
            // The save glyph (`square.and.arrow.down`) sits visually low — nudge it up 2pt to centre it.
            controlButton("square.and.arrow.down", help: "Save game…", iconOffsetY: -2) { onSave() }
            controlButton("folder", help: "Load game…") { onLoad() }
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $showMentat) {
                NavigationStack {
                    MentatView(model: model, provider: sprites)
                    .navigationTitle("Mentat")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showMentat = false } }
                    }
                }
            }
        #else
            .popover(isPresented: $showMentat, arrowEdge: .bottom) {
                MentatView(model: model, provider: sprites)
            }
        #endif
        // Freeze the game while either surface is open, resuming to the player's own pause state (balanced).
        .onChange(of: showOptions) { _, open in open ? model.beginUIPause() : model.endUIPause() }
        .onChange(of: showMentat) { _, open in open ? model.beginUIPause() : model.endUIPause() }
    }

    // Circular Liquid-Glass buttons (no backing pane — each button is its own glass disc over the map).
    private func controlButton(
        _ systemImage: String,
        help: String,
        iconOffsetY: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .offset(y: iconOffsetY)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).help(help)
    }
}
