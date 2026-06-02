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
        .library(name: "DuneIIScenarios", targets: [ "DuneIIScenarios" ]),
        .executable(name: "assetgen", targets: [ "assetgen" ]),
        .executable(name: "duneii-headless", targets: [ "duneii-headless" ]),
        .executable(name: "rendertest", targets: [ "rendertest" ]),
        .executable(name: "mapview", targets: [ "mapview" ]),
        .executable(name: "duneii", targets: [ "duneii" ]),
        .executable(name: "rendercap", targets: [ "rendercap" ]),
        .executable(name: "scenariolab", targets: [ "scenariolab" ]),
    ],
    dependencies: [
        // SwiftOPL3 — pure-Swift OPL3 (YMF262) chip + Westwood ADL music driver. Powers the authentic AdLib
        // FM music backend (DuneIIAudio/ADLMusicPlayer). The author's URL is SSH (git@github.com:bealex/
        // SwiftOLP3.git); we resolve the same repo over HTTPS so it works in sandboxed/CI builds without SSH.
        // Tracking `main` while the synth is actively being optimised (the speedup work landed there ahead of a
        // tagged release); `Package.resolved` still pins the exact commit, so builds stay reproducible. Switch
        // back to `from: "1.x"` once a release ≥ the speedup is tagged.
        .package(url: "https://github.com/bealex/SwiftOLP3.git", branch: "main"),
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
            dependencies: [
                "DuneIIContracts",
                .product(name: "SwiftOPL3", package: "SwiftOLP3"),
                .product(name: "WestwoodADL", package: "SwiftOLP3"),
            ],
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

        // Behavioural scenario harness — the shared headless model (terrain + scenarios + runner) used
        // by the scenariolab app and the OpenDUNE scenario-golden tests. See Architecture/ScenarioHarness.md.
        .target(
            name: "DuneIIScenarios",
            dependencies: [ "DuneIISimulation", "DuneIIWorld", "DuneIIFormats", "DuneIIContracts" ],
            path: "Frameworks/DuneIIScenarios",
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
            dependencies: [ "DuneIIContracts", "DuneIIFormats", "DuneIIWorld", "DuneIISimulation",
                            "DuneIIScenarios", "DuneIIRenderer", "DuneIIInput", "DuneIIAudio" ],
            path: "Apps/duneii-headless"
        ),
        // Native macOS SwiftUI asset inspector (render-test app). Builds via `swift run rendertest`.
        .executableTarget(
            name: "mapview",
            dependencies: [ "DuneIISimulation", "DuneIIWorld", "DuneIIFormats", "DuneIIRenderer", "DuneIIContracts", "DuneIIInput", "DuneIIAudio" ],
            path: "Apps/mapview"
        ),
        // The native macOS game client (Phase 6 host) — a SwiftUI main map window + floating AppKit tool
        // windows (minimap, inspector, economy, debug). Non-Catalyst (pivoted from Catalyst).
        .executableTarget(
            name: "duneii",
            dependencies: [ "DuneIISimulation", "DuneIIWorld", "DuneIIFormats", "DuneIIRenderer", "DuneIIContracts", "DuneIIInput", "DuneIIAudio" ],
            path: "Apps/duneii"
        ),
        .executableTarget(
            name: "rendertest",
            dependencies: [ "DuneIIFormats", "DuneIIRenderer", "DuneIIExport", "DuneIIAudio" ],
            path: "Apps/rendertest"
        ),
        // Headless render-capture tool: run a scenario to a tick, snapshot a region via the real renderer → PNG.
        .executableTarget(
            name: "rendercap",
            dependencies: [ "DuneIIContracts", "DuneIIFormats", "DuneIIWorld", "DuneIISimulation",
                            "DuneIIRenderer", "DuneIIExport" ],
            path: "Apps/rendercap"
        ),
        // Behavioural scenario lab — pick a terrain/units/scenario, run it, assess visually (1×–16×).
        .executableTarget(
            name: "scenariolab",
            dependencies: [ "DuneIIScenarios", "DuneIISimulation", "DuneIIWorld", "DuneIIFormats", "DuneIIRenderer", "DuneIIContracts" ],
            path: "Apps/scenariolab"
        ),

        // Tests (one per tested target; the DuneII prefix is dropped).
        .testTarget(name: "ContractsTests", dependencies: [ "DuneIIContracts" ], path: "Tests/ContractsTests"),
        .testTarget(name: "InputTests", dependencies: [ "DuneIIInput", "DuneIIContracts" ], path: "Tests/InputTests"),
        .testTarget(
            name: "AudioTests",
            dependencies: [
                "DuneIIAudio", "DuneIIContracts",
                .product(name: "SwiftOPL3", package: "SwiftOLP3"),
                .product(name: "WestwoodADL", package: "SwiftOLP3"),
            ],
            path: "Tests/AudioTests"
        ),
        .testTarget(name: "FormatsTests", dependencies: [ "DuneIIFormats" ], path: "Tests/FormatsTests"),
        .testTarget(name: "WorldTests", dependencies: [ "DuneIIWorld" ], path: "Tests/WorldTests", exclude: [ "Fixtures" ]),
        .testTarget(name: "SimulationTests", dependencies: [ "DuneIISimulation" ], path: "Tests/SimulationTests"),
        .testTarget(name: "ExportTests", dependencies: [ "DuneIIExport", "DuneIIFormats" ], path: "Tests/ExportTests"),
        .testTarget(name: "RendererTests", dependencies: [ "DuneIIRenderer", "DuneIIFormats", "DuneIIContracts" ], path: "Tests/RendererTests"),
        .testTarget(name: "ScenariosTests", dependencies: [ "DuneIIScenarios" ], path: "Tests/ScenariosTests", exclude: [ "Fixtures" ]),
        // Render-golden integration: run a scenario through the real sim + renderer, diff the captured
        // frame pixel-exact against a committed reference PNG (spans Simulation + Renderer, so a target of
        // its own). References live in Fixtures/ and are regenerated by Scripts/gen-render-goldens.sh.
        .testTarget(
            name: "RenderGoldenTests",
            dependencies: [ "DuneIIRenderer", "DuneIISimulation", "DuneIIWorld", "DuneIIFormats", "DuneIIContracts" ],
            path: "Tests/RenderGoldenTests", exclude: [ "Fixtures" ]
        ),
    ]
)
