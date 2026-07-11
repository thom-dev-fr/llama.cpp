// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LlamaEngine",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "LlamaEngine",
            targets: ["LlamaEngine"]
        ),
        .library(
            name: "LlamaLanguageModel",
            targets: ["LlamaLanguageModel"]
        ),
        .library(
            name: "LlamaServerLanguageModel",
            targets: ["LlamaServerLanguageModel"]
        ),
        .library(
            name: "LlamaOpenAICompatible",
            targets: ["LlamaOpenAICompatible"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "LlamaEngineCore",
            path: "build/LlamaEngineCore.xcframework"
        ),
        .target(
            name: "LlamaEngine",
            dependencies: ["LlamaEngineCore"]
        ),
        .target(
            name: "LlamaOpenAICompatible",
            swiftSettings: [
                .enableExperimentalFeature("InternalImportsByDefault"),
                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "LlamaLanguageModel",
            dependencies: [
                "LlamaEngine",
                "LlamaOpenAICompatible",
            ],
            swiftSettings: [
                .enableExperimentalFeature("InternalImportsByDefault"),
                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "LlamaServerLanguageModel",
            dependencies: [
                "LlamaOpenAICompatible",
            ],
            swiftSettings: [
                .enableExperimentalFeature("InternalImportsByDefault"),
                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "LlamaEngineTests",
            dependencies: [
                "LlamaEngine",
                "LlamaLanguageModel",
                "LlamaOpenAICompatible",
                "LlamaServerLanguageModel",
            ],
            path: "Tests"
        ),
    ]
)
