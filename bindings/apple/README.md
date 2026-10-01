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

## Runtime and model store

The application creates one `LlamaRuntime` and shares it between its
sessions; there is no singleton. It owns the native engine, the catalog and
the admission queue. Conversations stay with the callers.

```swift
import LlamaEngine

let store = try LlamaModelStore.applicationSupport()     // Application Support/LlamaModels
let runtime = try LlamaRuntime(
    configuration: .init(limits: .init(maximumResidentModels: 1,
                                       maximumActiveGenerations: 1,
                                       maximumWaitingRequests: 4)),
    store: store)

let qwen = try await runtime.importModel(LlamaModelImport(
    id: LlamaModelID("qwen3.5-2b"), weights: pickedGGUF, projector: pickedProjector))
let profile = LlamaLoadProfile(contextSize: 4096, usesProjector: true)
try await runtime.load(qwen.id, profile: profile)         // optional: generations load on demand

for await update in runtime.updates() {                   // snapshot, then changes (or a resync)
    render(update.snapshot)
}
```

- **Artifact, profile, instance.** A `LlamaModelArtifact` names files
  (weights, all shards of a split model, optional projector). A
  `LlamaLoadProfile` says how to load them (context per generation, compute,
  projector, template, extra engine options). Requests with the same artifact
  and profile share one loaded instance; another profile gets its own.
- **Admission.** At most `maximumActiveGenerations` generations run; at most
  `maximumWaitingRequests` wait, first come first served; beyond that a
  request fails at once with `LlamaEngineError.queueFull`. A wait can be
  cancelled (its place is freed once) and is bounded by `admissionTimeout`.
  This queue is the only admission authority: each instance has one engine
  slot per allowed generation, so the engine never queues an admitted
  generation for a slot.
- **Unload.** `unload(_:)` closes the model's admissions, ends its waiting
  and running generations with `LlamaEngineError.unloaded`, and returns once
  the engine freed its resources; it runs on worker threads, never on the
  caller's. A later request loads the model again.
- **Observation.** `snapshot()` and `updates()` report the catalog, each
  instance's state (loading progress, loaded, failed, ...) and the admission
  counts. A subscriber that falls `observationBufferLimit` updates behind gets
  one `resync` with the number of dropped updates.
- **Store.** `importModel` copies the files into the store (a clone on APFS),
  writes a manifest, then renames the directory into place: a model is
  complete or absent. It checks GGUF files, every announced shard and the
  free space first. Model directories are excluded from backups. `removeModel`
  ends the model's work, then deletes the managed copy; the imported source
  and files added with `register(_:)` are never deleted.

## Tests

```bash
cd bindings/apple
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`LlamaEngineTests` (native layer and runtime) load the small model
`tools/server/tests/tmp/stories15M-q4_0.gguf` (CPU), the draft model that the
server tests download. Without it:

```bash
curl -L -o tools/server/tests/tmp/stories15M-q4_0.gguf https://huggingface.co/ggml-org/tiny-llamas/resolve/main/stories15M-q4_0.gguf
```

The package requires OS 27 at run time: on an older Mac, tests compile but run
only on an iOS 27 simulator or device.
