import Foundation

public enum LandscapeType: Int, Sendable, CaseIterable {
    case normalSand = 0
    case partialRock = 1
    case entirelyDune = 2
    case partialDune = 3
    case entirelyRock = 4
    case mostlyRock = 5
    case entirelyMountain = 6
    case partialMountain = 7
    case spice = 8
    case thickSpice = 9
    case concreteSlab = 10
    case wall = 11
    case structure = 12
    case destroyedWall = 13
    case bloomField = 14
}

/// The 81-entry landscape-sprite → `LandscapeType` lookup used by
/// OpenDUNE's `Map_GetLandscapeType`. Copied verbatim from `map.c`.
internal enum LandscapeLookup {
    static let spriteToLandscape: [LandscapeType] = [
        // Sprites 127-136
        .normalSand, .partialRock, .partialRock, .partialRock, .mostlyRock,
        .partialRock, .mostlyRock, .mostlyRock, .mostlyRock, .mostlyRock,
        // Sprites 137-146
        .mostlyRock, .mostlyRock, .mostlyRock, .mostlyRock, .mostlyRock, .mostlyRock,
        .entirelyRock, .partialDune, .partialDune, .partialDune,
        // Sprites 147-156
        .partialDune, .partialDune, .partialDune, .partialDune, .partialDune,
        .partialDune, .partialDune, .partialDune, .partialDune, .partialDune,
        // Sprites 157-166
        .partialDune, .partialDune, .entirelyDune, .partialMountain, .partialMountain,
        .partialMountain, .partialMountain, .partialMountain, .partialMountain, .partialMountain,
        // Sprites 167-176
        .partialMountain, .partialMountain, .partialMountain, .partialMountain, .partialMountain,
        .partialMountain, .partialMountain, .partialMountain, .entirelyMountain, .spice,
        // Sprites 177-186
        .spice, .spice, .spice, .spice, .spice, .spice, .spice, .spice, .spice, .spice,
        // Sprites 187-196
        .spice, .spice, .spice, .spice, .spice, .thickSpice, .thickSpice, .thickSpice,
        .thickSpice, .thickSpice,
        // Sprites 197-206
        .thickSpice, .thickSpice, .thickSpice, .thickSpice, .thickSpice, .thickSpice,
        .thickSpice, .thickSpice, .thickSpice, .thickSpice,
        // Sprite 207
        .thickSpice
    ]
}
