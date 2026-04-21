import Foundation

/// Runtime entity tables. Every live unit, structure, and house lives in
/// a fixed-size pool with a stable slot index. Indices are persistent
/// identifiers used by save files and inter-entity links; getting them
/// wrong means save divergence. See `Documentation/Architecture/Pools.md`.
public enum Simulation {}
