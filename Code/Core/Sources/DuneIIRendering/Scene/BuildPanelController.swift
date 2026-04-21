import Foundation
import DuneIICore

/// Pure state machine sitting between `ScenarioScene` mouse events and
/// `Simulation.Structures.create` / `.startConstruction`. Testable
/// without SpriteKit / AppKit.
///
/// Lifecycle:
/// - The scene refreshes `availableTypes` and the selected yard's live
///   state (via `refreshAvailableTypes` / `refreshYardState`) whenever
///   pool state changes.
/// - The scene translates each `NSEvent` into a `Click` and calls
///   `handle(click:)`.
/// - `handle` returns an `Action` the scene acts on:
///   `.enqueue(type:)` → `Simulation.Structures.startConstruction`;
///   `.enterPlacement(type:)` → start hovering;
///   `.commitPlacement(...)` → validate + `Simulation.Structures.create`.
///
/// See `Documentation/Algorithms/BuildPanel.md` and
/// `Documentation/Algorithms/BuildPanelProgress.md` (slice 4d-ui).
public struct BuildPanelController: Equatable, Sendable {
    public var selectedYardIndex: Int?
    public var placementType: UInt8?
    public var availableTypes: [UInt8]
    /// Live state of the selected yard. `nil` until the scene calls
    /// `refreshYardState` for the first time — in that degraded state
    /// the controller treats sidebar clicks as "start construction"
    /// (slice-3 behaviour).
    public var yardState: Simulation.StructureState?
    /// The type the selected yard is currently producing (or has
    /// produced), `0xFFFF` in the slot being decoded to `nil` here.
    public var queuedType: UInt8?
    /// Current `countDown` on the selected yard (`buildTime << 8` when
    /// freshly queued; 0 when READY).
    public var countDown: UInt16?
    /// Original `buildTime` of the queued type; stored so the UI can
    /// compute progress.
    public var buildTime: UInt16?

    public init(
        selectedYardIndex: Int? = nil,
        placementType: UInt8? = nil,
        availableTypes: [UInt8] = [],
        yardState: Simulation.StructureState? = nil,
        queuedType: UInt8? = nil,
        countDown: UInt16? = nil,
        buildTime: UInt16? = nil
    ) {
        self.selectedYardIndex = selectedYardIndex
        self.placementType = placementType
        self.availableTypes = availableTypes
        self.yardState = yardState
        self.queuedType = queuedType
        self.countDown = countDown
        self.buildTime = buildTime
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
        /// Queue construction on the selected yard. Scene should call
        /// `Simulation.Structures.startConstruction(...)`.
        case enqueue(type: UInt8)
        /// Enter placement mode — scene should render a placement
        /// cursor and wait for a map click.
        case enterPlacement(type: UInt8)
        /// Commit a placement at the given tile. Scene should call
        /// `Simulation.Structures.create(...)`.
        case commitPlacement(type: UInt8, tileX: Int, tileY: Int)
        /// Cancel the current BUSY / READY construction. Scene should
        /// call `Simulation.Structures.cancelConstruction(...)`.
        /// Slice 5c.
        case cancelConstruction(type: UInt8)
    }

    /// 0.0 at build start, 1.0 at READY. Returns `nil` when either
    /// `countDown` or `buildTime` haven't been populated, or when
    /// `buildTime` is zero (avoids division by zero).
    public var progress: Double? {
        guard let countDown, let buildTime, buildTime > 0 else { return nil }
        let total = Double(buildTime) * 256.0
        let done = total - Double(countDown)
        return max(0.0, min(1.0, done / total))
    }

    /// Overwrites `availableTypes`. Does not touch `placementType` —
    /// a re-pick after a refresh behaves the same as any sidebar click.
    public mutating func refreshAvailableTypes(_ types: [UInt8]) {
        self.availableTypes = types
    }

    /// Scene pushes the selected yard's current state so the click
    /// handler can branch on IDLE / BUSY / READY. Called every tick
    /// after the scheduler runs.
    public mutating func refreshYardState(
        _ state: Simulation.StructureState?,
        queuedType: UInt8?,
        countDown: UInt16?,
        buildTime: UInt16?
    ) {
        self.yardState = state
        self.queuedType = queuedType
        self.countDown = countDown
        self.buildTime = buildTime
    }

    public mutating func handle(click: Click) -> Action {
        switch click {
        case .sidebarSlot(let index):
            guard index >= 0, index < availableTypes.count else { return .none }
            let type = availableTypes[index]
            switch yardState {
            case .busy:
                // Slice 5c: click on the queued type cancels the
                // current build. Click on a different type during
                // BUSY is a no-op (no mid-build swap — OpenDUNE
                // matches this).
                if let queuedType, type == queuedType {
                    return .cancelConstruction(type: type)
                }
                return .none
            case .ready:
                if let queuedType, type == queuedType {
                    placementType = type
                    return .enterPlacement(type: type)
                }
                // Slice 5c: READY + different type → queue-swap.
                // `startConstruction` accepts a non-BUSY yard so
                // routing through `.enqueue` replaces the queue.
                placementType = nil
                return .enqueue(type: type)
            case nil, .idle, .justBuilt, .detect:
                // Idle (or not-yet-populated) yard → start construction.
                placementType = nil
                return .enqueue(type: type)
            }
        case .mapTile(let x, let y):
            guard let type = placementType else { return .none }
            placementType = nil
            return .commitPlacement(type: type, tileX: x, tileY: y)
        case .outside:
            return .none
        }
    }
}
