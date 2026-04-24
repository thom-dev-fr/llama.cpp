// swift-tools-version:5.9
import PackageDescription

// LlamaChatDemo — exemple minimal SwiftUI exploitant le produit `LlamaEngine`
// exposé par le package racine de ce fork (llama.cpp/Package.swift).
//
// Prérequis : avoir construit au préalable le xcframework :
//
//     ./apple/scripts/build-xcframework.sh
//
// Lancement (macOS) :
//
//     cd apple/examples/LlamaChatDemo
//     swift run LlamaChatDemo
//
// Pour iOS : ouvrir ce Package.swift dans Xcode, sélectionner un device, Run.

let package = Package(
    name: "LlamaChatDemo",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "LlamaChatDemo",
            dependencies: [
                .product(name: "LlamaEngine", package: "llama.cpp"),
            ],
            path: "Sources/LlamaChatDemo"
        ),
    ]
)
