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

## Model catalog and downloads

`Catalog/models.json` is a versioned manifest (`LlamaModelCatalog`, format 1)
of downloadable models. Each entry pins its files to an immutable source
revision with their size and SHA-256, and records the projector, the license,
the chat template, the capabilities the model **declares** and those
**qualified** with this library (only these may be offered to Foundation
Models; none yet, see the report). `LlamaModelCatalog.decode` refuses another
format version, a moving revision (`main`), a URL that does not contain the
revision, a non-https URL (http only to the loopback interface, for tests),
invalid names, digests or shard sequences, and vision without a projector.

Check the references of a catalog against the servers (and local copies):

```bash
bindings/apple/Catalog/verify-catalog.py --local ~/.cache/huggingface/hub/models--unsloth--Qwen3.5-2B-GGUF/snapshots/<revision>
```

`LlamaModelDownloads` transfers a catalog entry with `URLSession`, then
installs it in the runtime's store:

```swift
let catalog = try LlamaModelCatalog.decode(Data(contentsOf: catalogURL))
let downloads = try LlamaModelDownloads(runtime: runtime)   // background session, created at launch
try downloads.start(catalog[LlamaModelID("qwen3.5-2b-q4_k_m")]!)
for await update in downloads.updates() { render(update.snapshot) }
try await downloads.pause(id); try downloads.resume(id); try await downloads.cancel(id)
```

- **States.** `downloading`, `paused`, `interrupted(issue)` (recoverable:
  network, server unavailable, the application ended), `verifying`,
  `installing`, `failed(issue)` (HTTP error, size or digest mismatch, no
  space, installation). `resume` continues a paused or interrupted download
  from its resume data when the server allows it (validator and byte ranges);
  otherwise, or when the resume data is unusable, the file restarts from the
  beginning. After a failure, `resume` restarts the failed file; the other
  files keep their data. `cancel` abandons the download and deletes its data;
  it is refused once the installation started.
- **Loadable only when complete.** Files are transferred into
  `<store>/downloads/<id>`, never into the catalog. Once every file has the
  catalog's size and SHA-256 (checked off the cooperative pool), they move
  into the store in one rename and the model appears in the runtime with its
  `catalogEntry`. A missing or partial projector never yields a model with
  vision.
- **Persistence.** Each download keeps `record.json` and its resume data.
  Transfer tasks carry their identity (model, file, token) in
  `taskDescription`; a new instance with the same session identifier
  reattaches the tasks the system kept, verifies files received meanwhile,
  and reports transfers that did not survive as `interrupted`. Nothing
  restarts on its own.
- **Application lifecycle (iOS).** Create the object at launch with the same
  identifier and keep it for the application's life; forward background
  session events (`handleBackgroundEvents(forSession:completionHandler:)`
  from the application delegate, or `await downloads.backgroundEventsFinished()`
  in SwiftUI's `.backgroundTask(.urlSession(_:))`). The system continues the
  transfers while the application is suspended or terminated by the system;
  it cancels them when the user force quits the application, and they show
  as `interrupted` at the next launch. A background session needs an
  application: the system refuses it to command-line processes such as the
  `xctest` tool. `Configuration(sessionIdentifier: nil)` uses a foreground
  session, whose transfers end with the process.

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

`DownloadTests` run against a local HTTP server controlled by the tests
(interrupted transfers, servers with and without byte ranges, files changed
on the server, HTTP errors, pause, abandon, relaunch). Two tests are skipped
by default:

- `backgroundSessionDownloads` runs only in an application host (the system
  refuses background sessions to the `xctest` tool);
- `realCatalogEntryDownloadsAndInstalls` downloads the shipped catalog entry
  from Hugging Face (about 2 GB):

```bash
TEST_RUNNER_LLAMA_DOWNLOAD_REAL_CATALOG=1 xcodebuild test -scheme LlamaApple-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'LlamaEngineTests/DownloadTests/realCatalogEntryDownloadsAndInstalls()'
```

The package requires OS 27 at run time: on an older Mac, tests compile but run
only on an iOS 27 simulator or device.
