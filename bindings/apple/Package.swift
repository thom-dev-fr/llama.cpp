// swift-tools-version: 6.2

import PackageDescription

// P0 skeleton: the native engine (bridge + XCFramework) is added in P2.
// Until then the modules compile for iOS 27 and macOS 27 and refuse every
// request explicitly; no capability is declared.
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
        .target(name: "LlamaEngine"),
        .target(
            name: "LlamaFoundationModels",
            dependencies: ["LlamaEngine"]
        ),
        .testTarget(
            name: "LlamaFoundationModelsTests",
            dependencies: ["LlamaFoundationModels", "LlamaEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
