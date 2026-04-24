// swift-tools-version:5.9
import PackageDescription

// NOTE: the xcframework is NOT committed to the repository.
// Build it first with `apple/scripts/build-xcframework.sh`; the resulting
// `apple/build/LlamaEngineCore.xcframework` is what this Package.swift refers to.

let package = Package(
    name: "LlamaEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "LlamaEngine",
            targets: ["LlamaEngine"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "LlamaEngineCore",
            path: "apple/build/LlamaEngineCore.xcframework"
        ),
        .target(
            name: "LlamaEngine",
            dependencies: ["LlamaEngineCore"],
            path: "apple/Sources/LlamaEngine"
        ),
    ]
)
