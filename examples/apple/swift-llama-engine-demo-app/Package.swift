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
    ]
)
