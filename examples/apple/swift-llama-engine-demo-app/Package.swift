// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LlamaChatDemo",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(
            name: "LlamaChatDemo",
            targets: ["LlamaChatDemo"]
        ),
        .executable(
            name: "LlamaRealtimeFileDemo",
            targets: ["LlamaRealtimeFileDemo"]
        ),
    ],
    dependencies: [
        .package(name: "LlamaEngine", path: "../swift-llama-engine"),
    ],
    targets: [
        .executableTarget(
            name: "LlamaChatDemo",
            dependencies: [
                .product(name: "LlamaEngine", package: "LlamaEngine"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "LlamaRealtimeFileDemo",
            dependencies: [
                .product(name: "LlamaEngine", package: "LlamaEngine"),
            ],
            path: "RealtimeFileDemo"
        ),
    ]
)
