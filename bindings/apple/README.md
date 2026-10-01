# LlamaApple — llama.cpp for Foundation Models

Swift package that runs GGUF models with the llama.cpp inference engine
behind Apple's Foundation Models `LanguageModel` protocol (iOS 27, macOS 27).

| Module | Role |
| --- | --- |
| `LlamaFoundationModels` | `LlamaLanguageModel` and its executor for `LanguageModelSession`. |
| `LlamaEngine` | Runtime shared by the sessions, configuration, catalog and typed errors. |
| `LlamaBridge` (binary) | C bridge over the engine (`bridge/include/llama_bridge.h`); an integration detail, not used directly. |

Status, capability matrix and validation evidence:
[docs/design/apple-language-model-report.md](../../docs/design/apple-language-model-report.md).

## Build the native framework

`LlamaBridge.xcframework` is built from this checkout; it is not committed.

```bash
scripts/build-apple-language-model.sh
```

From the repository root, with Xcode 27 and CMake ≥ 3.21. The script builds
the C bridge with llama, ggml (Metal, shaders embedded), mtmd and the local
engine linked statically into one dynamic framework per platform:

| Slice | Architectures | Minimum OS |
| --- | --- | --- |
| iOS | arm64 | 27.0 |
| iOS Simulator | arm64, x86_64 | 27.0 |
| macOS | arm64, x86_64 | 27.0 |

Only the `llama_bridge_*` functions are exported. The network acquisition of
the engine is not included: downloads use `URLSession`.

Outputs (nothing else is cleaned):

- `bindings/apple/Frameworks/LlamaBridge.xcframework`, used by `Package.swift`;
- `build-apple-lm/LlamaBridge.xcframework.zip` and its SwiftPM checksum
  (`.zip.checksum`), for a release;
- `build-apple-lm/<platform>-<arch>/`, the CMake builds (incremental on the
  next run).

With `--test` and `LLAMA_BRIDGE_TEST_MODEL=/path/to/model.gguf`, the script also
builds the bridge for the Mac and runs its lifetime tests (C consumer).

## Use the package

Locally, once the framework is built:

```swift
.package(path: "../llama.cpp/bindings/apple")
// target dependency
.product(name: "LlamaFoundationModels", package: "apple")
```

A local package is identified by its directory name (`apple`).

The package refuses to resolve until `Frameworks/LlamaBridge.xcframework` exists.

### Publishing the binary (later)

For a release, upload `LlamaBridge.xcframework.zip` and replace the binary
target in `Package.swift` with its URL and the checksum printed by the script:

```swift
.binaryTarget(
    name: "LlamaBridge",
    url: "https://example.org/releases/<version>/LlamaBridge.xcframework.zip",
    checksum: "<content of LlamaBridge.xcframework.zip.checksum>"
),
```

The checksum changes with every build; publish the archive and the manifest
together.

## Tests

```bash
cd bindings/apple
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`LlamaEngineTests` load the small model
`tools/server/tests/tmp/stories15M-q4_0.gguf` (CPU), the draft model that the
server tests download. Without it:

```bash
curl -L -o tools/server/tests/tmp/stories15M-q4_0.gguf https://huggingface.co/ggml-org/tiny-llamas/resolve/main/stories15M-q4_0.gguf
```

The package requires OS 27 at run time: on an older Mac, tests compile but run
only on an iOS 27 simulator or device.
