// swift-tools-version: 6.2

import PackageDescription

// The native engine is the LlamaBridge binary target, built from this
// repository by scripts/build-apple-language-model.sh (see README.md).
let package = Package(
    name: "LlamaApple",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "LlamaEngine", targets: ["LlamaEngine"]),
        .library(name: "LlamaFoundationModels", targets: ["LlamaFoundationModels"]),
    ],
    targets: [
        .binaryTarget(name: "LlamaBridge", path: "Frameworks/LlamaBridge.xcframework"),
        .target(
            name: "LlamaEngine",
            dependencies: ["LlamaBridge"]
        ),
        .target(
            name: "LlamaFoundationModels",
            dependencies: ["LlamaEngine"]
        ),
        .testTarget(
            name: "LlamaFoundationModelsTests",
            dependencies: ["LlamaFoundationModels", "LlamaEngine"]
        ),
        .testTarget(
            name: "LlamaEngineTests",
            dependencies: ["LlamaEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
