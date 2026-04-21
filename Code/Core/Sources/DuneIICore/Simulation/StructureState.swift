import Foundation

extension Simulation {
    /// Typed constants over `StructureSlot.state: Int16`. Values mirror
    /// OpenDUNE's `STRUCTURE_STATE_*` enum in `src/structure.h`.
    /// Existing integer comparisons still work; this is a readability
    /// layer, not a replacement for the raw storage.
    public enum StructureState: Int16, Sendable, Equatable {
        /// Write-only sentinel meaning "resolve my state from linkedID /
        /// countDown". See `Script_Structure_SetState` for the resolution.
        case detect   = -2
        /// Freshly created; not yet participating in the tick loop.
        case justBuilt = -1
        /// Ready to build / idle.
        case idle     = 0
        /// Building something — `countDown` is draining.
        case busy     = 1
        /// Construction complete; player is expected to click-to-place.
        case ready    = 2
    }
}
