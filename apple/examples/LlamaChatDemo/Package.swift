// swift-tools-version:5.9
import PackageDescription

// LlamaChatDemo — exemple minimal SwiftUI exploitant le produit `LlamaEngine`
// exposé par le package racine de ce fork (llama.cpp/Package.swift).
//
// Deux modes de build (gérés par le Package.swift racine) :
//
// 1) Libs statiques (DÉFAUT — itération rapide, host uniquement) :
//
//        ./apple/scripts/build-static-libs.sh
//        cd apple/examples/LlamaChatDemo
//        swift run LlamaChatDemo
//
//    SwiftPM lit `apple/build/static-libs/macos/` par défaut. Pour pointer
//    ailleurs (ex. ios-sim), exporter `LLAMA_ENGINE_STATIC_LIBS_DIR`.
//
// 2) xcframework (opt-in, multi-plateforme) :
//
//        ./apple/scripts/build-xcframework.sh
//        export LLAMA_ENGINE_USE_XCFRAMEWORK=1
//        cd apple/examples/LlamaChatDemo
//        swift run LlamaChatDemo
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
