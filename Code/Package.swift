// swift-tools-version: 6.3
import PackageDescription

// Source trees are organized by kind, and each target's directory is set explicitly via `path:`
// (SPM's default `Sources/`/`Tests/` discovery is deliberately not used):
//   Frameworks/  — the DuneII* engine libraries.
//   Tools/       — command-line developer/build tools (asset extraction, fixture generation).
//   Apps/        — runnable end-products (the headless driver now; the Catalyst app + render-test app later).
//   Tests/       — one `<Subject>Tests` target per tested target.
// Adding a target = a new directory under the right tree + one entry below. This manifest is the
// single source of truth for the layout.

let package = Package(
    name: "DuneII",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "DuneIIContracts", targets: [ "DuneIIContracts" ]),
        .library(name: "DuneIIFormats", targets: [ "DuneIIFormats" ]),
        .library(name: "DuneIIWorld", targets: [ "DuneIIWorld" ]),
        .library(name: "DuneIISimulation", targets: [ "DuneIISimulation" ]),
        .library(name: "DuneIIRenderer", targets: [ "DuneIIRenderer" ]),
        .library(name: "DuneIIInput", targets: [ "DuneIIInput" ]),
        .library(name: "DuneIIAudio", targets: [ "DuneIIAudio" ]),
        .library(name: "DuneIIExport", targets: [ "DuneIIExport" ]),
        .executable(name: "assetgen", targets: [ "assetgen" ]),
        .executable(name: "duneii-headless", targets: [ "duneii-headless" ]),
        .executable(name: "rendertest", targets: [ "rendertest" ]),
        .executable(name: "mapview", targets: [ "mapview" ]),
    ],
    targets: [
        // Frameworks (the engine) — dependencies point downward only.
        .target(name: "DuneIIContracts", path: "Frameworks/DuneIIContracts", exclude: [ "CLAUDE.md" ]),
        .target(name: "DuneIIFormats", path: "Frameworks/DuneIIFormats", exclude: [ "CLAUDE.md" ]),
        .target(
            name: "DuneIIWorld",
            dependencies: [ "DuneIIContracts", "DuneIIFormats" ],
            path: "Frameworks/DuneIIWorld",
            exclude: [ "CLAUDE.md" ]
        ),
        .target(
            name: "DuneIISimulation",
            dependencies: [ "DuneIIWorld", "DuneIIContracts" ],
            path: "Frameworks/DuneIISimulation",
            exclude: [ "CLAUDE.md" ]
        ),
        .target(
            name: "DuneIIRenderer",
            dependencies: [ "DuneIIContracts", "DuneIIFormats" ],
            path: "Frameworks/DuneIIRenderer",
            exclude: [ "CLAUDE.md" ]
        ),
        .target(
            name: "DuneIIInput",
            dependencies: [ "DuneIIContracts" ],
            path: "Frameworks/DuneIIInput",
            exclude: [ "CLAUDE.md" ]
        ),
        .target(
            name: "DuneIIAudio",
            dependencies: [ "DuneIIContracts" ],
            path: "Frameworks/DuneIIAudio",
            exclude: [ "CLAUDE.md" ]
        ),
        // Asset writers (PNG via ImageIO/CoreGraphics, WAV via RIFF) — used by assetgen to export
        // decoded assets for visual/audio verification. Imports system frameworks, not a presentation leaf.
        .target(
            name: "DuneIIExport",
            dependencies: [ "DuneIIFormats" ],
            path: "Frameworks/DuneIIExport",
            exclude: [ "CLAUDE.md" ]
        ),

        // Tools (command-line).
        .executableTarget(
            name: "assetgen",
            dependencies: [ "DuneIIFormats", "DuneIIExport" ],
            path: "Tools/assetgen"
        ),

        // Apps (runnable end-products).
        .executableTarget(
            name: "duneii-headless",
            dependencies: [ "DuneIISimulation", "DuneIIRenderer", "DuneIIInput", "DuneIIAudio" ],
            path: "Apps/duneii-headless"
        ),
        // Native macOS SwiftUI asset inspector (render-test app). Builds via `swift run rendertest`.
        .executableTarget(
            name: "mapview",
            dependencies: [ "DuneIIWorld", "DuneIIFormats", "DuneIIRenderer", "DuneIIContracts" ],
            path: "Apps/mapview"
        ),
        .executableTarget(
            name: "rendertest",
            dependencies: [ "DuneIIFormats", "DuneIIRenderer", "DuneIIExport" ],
            path: "Apps/rendertest"
        ),

        // Tests (one per tested target; the DuneII prefix is dropped).
        .testTarget(name: "ContractsTests", dependencies: [ "DuneIIContracts" ], path: "Tests/ContractsTests"),
        .testTarget(name: "FormatsTests", dependencies: [ "DuneIIFormats" ], path: "Tests/FormatsTests"),
        .testTarget(name: "WorldTests", dependencies: [ "DuneIIWorld" ], path: "Tests/WorldTests", exclude: [ "Fixtures" ]),
        .testTarget(name: "SimulationTests", dependencies: [ "DuneIISimulation" ], path: "Tests/SimulationTests"),
        .testTarget(name: "ExportTests", dependencies: [ "DuneIIExport", "DuneIIFormats" ], path: "Tests/ExportTests"),
        .testTarget(name: "RendererTests", dependencies: [ "DuneIIRenderer", "DuneIIFormats" ], path: "Tests/RendererTests"),
    ]
)
