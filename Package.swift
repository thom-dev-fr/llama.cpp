// swift-tools-version:5.9
import PackageDescription
import Foundation

// LlamaEngine SwiftPM package — two build modes (default = static libs):
//
// 1. static libs from `apple/build/static-libs/macos/` opt-in via `useXcframework=false`
//    (or the
//    directory pointed at by `LLAMA_ENGINE_STATIC_LIBS_DIR` if it is set).
//    Build them once with:
//
//        ./apple/scripts/build-static-libs.sh           # macOS host
//        ./apple/scripts/build-static-libs.sh ios-sim   # iOS Simulator host arch
//        ./apple/scripts/build-static-libs.sh ios-device
//
//    SwiftPM then links the resulting `.a` files directly. This is the
//    fastest iteration path and is what the example app uses out of the box.
//
// 2. xcframework — opt-in via `useXcframework=true`.
//    Build the multi-slice xcframework first:
//
//        ./apple/scripts/build-xcframework.sh
//
//    Then any `swift build` / `swift run` invocation with that env var set
//    consumes `apple/build/LlamaEngineCore.xcframework` as a `binaryTarget`.

let env = ProcessInfo.processInfo.environment
let useXcframework = true

let coreTarget: Target
if useXcframework {
    coreTarget = .binaryTarget(
        name: "LlamaEngineCore",
        path: "apple/build/LlamaEngineCore.xcframework"
    )
} else {
    // Absolute path: relative paths are resolved against the build's CWD, which
    // varies between `swift run` and Xcode-driven builds. `Context.packageDirectory`
    // always points at this Package.swift's directory (the repo root).
    let defaultStaticLibsDir = "\(Context.packageDirectory)/apple/build/static-libs/macos"
    let staticLibsDir = env["LLAMA_ENGINE_STATIC_LIBS_DIR", default: defaultStaticLibsDir]
    coreTarget = .target(
        name: "LlamaEngineCore",
        path: "apple/llama-engine",
        exclude: [
            "CMakeLists.txt",
            "src",
        ],
        sources: ["spm-shim.c"],
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags([
                "-L\(staticLibsDir)",
                "-lllama-engine",
                "-lllama-common",
                "-lllama-common-base",
                "-lllama",
                "-lggml",
                "-lggml-base",
                "-lggml-cpu",
                "-lggml-metal",
                "-lggml-blas",
            ]),
            .linkedLibrary("c++"),
            .linkedFramework("Foundation"),
            .linkedFramework("Metal"),
            .linkedFramework("Accelerate"),
        ]
    )
}

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
        coreTarget,
        .target(
            name: "LlamaEngine",
            dependencies: ["LlamaEngineCore"],
            path: "apple/Sources/LlamaEngine"
        ),
    ]
)
