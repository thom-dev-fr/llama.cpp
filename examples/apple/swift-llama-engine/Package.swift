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
    ],
    targets: [
        .binaryTarget(
            name: "LlamaEngineCore",
            path: "build/LlamaEngineCore.xcframework"
        ),
        .target(
            name: "LlamaEngine",
            dependencies: ["LlamaEngineCore"],
            path: "Sources"
        ),
        .testTarget(
            name: "LlamaEngineTests",
            dependencies: ["LlamaEngine"],
            path: "Tests"
        ),
    ]
)
