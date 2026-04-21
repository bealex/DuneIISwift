import Foundation
import DuneIICore

/// Pure state machine sitting between `ScenarioScene` mouse events and
/// `Simulation.Structures.create`. Testable without SpriteKit / AppKit.
///
/// Shape:
/// - `availableTypes` is refreshed by the scene whenever the live
///   `structuresBuilt` bitmask changes (e.g. after a commit, after a
///   different yard gets selected).
/// - `placementType` reflects whether the user has picked a sidebar slot
///   and is waiting to click a map tile.
/// - `selectedYardIndex` is set by the scene (currently on first-yard
///   auto-select); read by the scene when resolving which yard to
///   query for `buildableStructuresFromYard`.
///
/// The controller does *not* decide which house owns the yard or
/// evaluate buildability — that all belongs to the scene + sim. It just
/// threads clicks into a consistent action for the scene to act on.
///
/// See `Documentation/Algorithms/BuildPanel.md`.
public struct BuildPanelController: Equatable, Sendable {
    public var selectedYardIndex: Int?
    public var placementType: UInt8?
    public var availableTypes: [UInt8]

    public init(
        selectedYardIndex: Int? = nil,
        placementType: UInt8? = nil,
        availableTypes: [UInt8] = []
    ) {
        self.selectedYardIndex = selectedYardIndex
        self.placementType = placementType
        self.availableTypes = availableTypes
    }

    /// A mouse click, classified against the sidebar / map split.
    /// `.outside` covers HUD space, banner space, and any non-interactive
    /// region.
    public enum Click: Equatable, Sendable {
        case sidebarSlot(index: Int)
        case mapTile(x: Int, y: Int)
        case outside
    }

    /// Scene-observable result of processing a click.
    public enum Action: Equatable, Sendable {
        case none
        case enterPlacement(type: UInt8)
        case commitPlacement(type: UInt8, tileX: Int, tileY: Int)
    }

    /// Overwrites `availableTypes`. Does not touch `placementType` —
    /// a re-pick after a refresh behaves the same as any sidebar click.
    public mutating func refreshAvailableTypes(_ types: [UInt8]) {
        self.availableTypes = types
    }

    public mutating func handle(click: Click) -> Action {
        switch click {
        case .sidebarSlot(let index):
            guard index >= 0, index < availableTypes.count else { return .none }
            let type = availableTypes[index]
            placementType = type
            return .enterPlacement(type: type)
        case .mapTile(let x, let y):
            guard let type = placementType else { return .none }
            placementType = nil
            return .commitPlacement(type: type, tileX: x, tileY: y)
        case .outside:
            return .none
        }
    }
}
