import DuneIIInput

/// A presentation-ready snapshot of the selected unit/structure for the inspector panel — derived from the
/// live `GameState` each frame, but a plain value type so the SwiftUI inspector stays decoupled from the
/// simulation model. `Equatable`, so the scene republishes only when something the panel shows changes.
struct SelectionInfo: Equatable {
    enum Kind: Equatable { case unit, structure }
    var kind: Kind
    var name: String        // type display name (e.g. "Siege Tank", "Refinery")
    var house: String       // owning house display name
    var hitpoints: Int
    var hitpointsMax: Int
    var tileX: Int
    var tileY: Int

    /// The commands the inspector offers for this selection. Structures have none in this first version.
    var commands: [OrderKind] { kind == .unit ? [.move, .attack] : [] }
    var canStop: Bool { kind == .unit }
}
