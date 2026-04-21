// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DuneIICore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DuneIICore", targets: ["DuneIICore"]),
        .library(name: "AssetExport", targets: ["AssetExport"]),
        .library(name: "DuneIIRendering", targets: ["DuneIIRendering"]),
        .executable(name: "assetgen", targets: ["assetgen"]),
        .executable(name: "duneii", targets: ["duneii"])
    ],
    dependencies: [
        .package(url: "https://github.com/bealex/memoirs-ios.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "DuneIICore",
            dependencies: [
                .product(name: "Memoirs", package: "memoirs-ios")
            ],
            path: "Sources/DuneIICore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "AssetExport",
            dependencies: ["DuneIICore"],
            path: "Sources/AssetExport",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "DuneIIRendering",
            dependencies: ["DuneIICore", "AssetExport"],
            path: "Sources/DuneIIRendering",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "assetgen",
            dependencies: ["DuneIICore", "AssetExport"],
            path: "Sources/assetgen"
        ),
        .executableTarget(
            name: "duneii",
            dependencies: ["DuneIICore", "AssetExport", "DuneIIRendering"],
            path: "Sources/duneii"
        ),
        .testTarget(
            name: "DuneIICoreTests",
            dependencies: ["DuneIICore", "AssetExport", "DuneIIRendering"],
            path: "Tests/DuneIICoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
