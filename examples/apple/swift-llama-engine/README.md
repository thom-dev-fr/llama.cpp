# LlamaEngine

Apple adapter for the portable `llama-engine`, packaged as an xcframework consumable via SwiftPM.

This example contains the Swift package and Apple build scripts for `llama-engine`. The portable C/C++ engine lives in the repository root under `engine/`. A SwiftUI demo app lives next to this package in `examples/apple/swift-llama-engine-demo-app/`.

## Overview

```
engine/
|-- include/             # Public C header (llama_engine.h)
|-- src/                 # Engine core, lifecycle, chat route adapter, params translator, C API bridge
|-- tests/               # Unit tests for pure C++ helpers
`-- CMakeLists.txt       # Built in-tree via the LLAMA_BUILD_ENGINE option

examples/apple/swift-llama-engine/
|-- Package.swift                    # SwiftPM package consumed by apps
|-- Sources/LlamaEngine/             # Swift facade (thread-safe class + value types)
|-- Sources/LlamaLanguageModel/      # Foundation Models adapter for local llama inference
|-- Sources/LlamaServerLanguageModel/# Foundation Models adapter for llama-server HTTP inference
|-- Sources/LlamaOpenAICompatible/   # Shared OpenAI-compatible codec, usage, and telemetry mapping
`-- scripts/                         # build-xcframework.sh
```

## Scope

- Single model lifecycle: `load` / `unload` / `pause` / `resume`
- Chat completions (OpenAI-compatible JSON in/out)
    - Non-stream: `chatCompletion(requestJSON:) async throws -> String`
    - Stream: `chatCompletionStream(requestJSON:) async throws -> EngineStream`
- Multimodal inputs (image / audio) via the OpenAI `image_url` / `input_audio` content parts, gated by the projector shipped with the model
- Tokenize / detokenize
- Metal GPU backend with embedded library
- Thread-safe via the C++ Engine Core, with Swift `EngineStream.cancel()` propagating into `server-context` cancel tasks

Out of scope for now: embeddings, rerank, multiple concurrent models, parallel sampling (`n > 1`).

## Build

Prerequisites: Xcode 15+, CMake 3.28+.

By default, the script builds a production-ready Release xcframework with all supported slices: iOS device, iOS simulator, and macOS.

```bash
# From the repo root
./examples/apple/swift-llama-engine/scripts/build-xcframework.sh
```

For faster development builds, select one platform and Debug configuration. Use `--no-clean` to keep the native build directory for incremental C++ rebuilds:

```bash
./examples/apple/swift-llama-engine/scripts/build-xcframework.sh --platform ios --debug --no-clean
```

The script writes `examples/apple/swift-llama-engine/build/LlamaEngineCore.xcframework`, the binary target referenced by `examples/apple/swift-llama-engine/Package.swift`.

## Integration (from a sibling app repo)

Assuming your app repository and this repository are checked out next to each other:

In the app's `Package.swift`:

```swift
.package(name: "LlamaEngine", path: "../llama.cpp/examples/apple/swift-llama-engine")
```

Add `LlamaEngine` as a product dependency on any target.

## Usage

```swift
import LlamaEngine

let engine = LlamaEngine()
LlamaEngine.setLogLevel(.info)

try await engine.load(ModelConfig(
    modelPath: URL(fileURLWithPath: "/path/to/Meta-Llama-3-8B-Instruct.Q4_K_M.gguf"),
    contextSize: 4096,
    gpuLayers: -1,
    flashAttention: true
))

let request = #"""
{
  "messages": [{"role": "user", "content": "Say hello."}],
  "temperature": 0.7,
  "stream": true
}
"""#

let stream = try await engine.chatCompletionStream(requestJSON: request)
for try await chunk in stream {
    print(chunk)
}

try await engine.unload()
```

## Multimodal inputs (image / audio)

Pass an `mmproj` file (the projector that comes with the model, e.g. `mmproj-F16.gguf`) via `ModelConfig.mtmdProjectorPath`:

```swift
try await engine.load(ModelConfig(
    modelPath:          URL(fileURLWithPath: "…/Qwen2-VL-7B-Instruct-Q4_K_M.gguf"),
    mtmdProjectorPath:  URL(fileURLWithPath: "…/Qwen2-VL-7B-mmproj-F16.gguf")
))

// Ask the engine what the loaded model supports — *without* loading it.
// `LlamaEngine.modelInfo(...)` only reads GGUF metadata (no weights, no
// Metal init) so you can probe a freshly-downloaded model before deciding
// whether to load it / register it in your app.
let info = try await LlamaEngine.modelInfo(
    modelURL:  URL(fileURLWithPath: "…/Qwen2-VL-7B-Instruct-Q4_K_M.gguf"),
    mmprojURL: URL(fileURLWithPath: "…/Qwen2-VL-7B-mmproj-F16.gguf")
)
print(info.architecture, info.sizeLabel ?? "?", info.quantization ?? "?")
print(info.capabilities.supportsVision, info.capabilities.supportsAudio)
print(info.capabilities.supportsToolCalls, info.capabilities.supportsReasoning)
```

Then send a standard OpenAI multi-part `content`:

```json
{
    "messages": [
        {
            "role": "user",
            "content": [
                { "type": "text", "text": "What's in this picture?" },
                {
                    "type": "image_url",
                    "image_url": {
                        "url": "data:image/png;base64,iVBORw0KGgo..."
                    }
                }
            ]
        }
    ]
}
```

For audio, use `input_audio` with a base64-encoded `wav` or `mp3` payload:

```json
{
    "type": "input_audio",
    "input_audio": { "data": "…base64…", "format": "wav" }
}
```

Notes:

- `http://` URLs do not work — the xcframework is built with `LLAMA_HTTPLIB=OFF`.
  Use a data URL (base64) or a `file://` URL (see `media_path` below).
- `file://` URLs require the path gate: set `extraJSON: #"{"media_path":"/some/dir"}"#`
  in `ModelConfig`. Only the specified directory and its relative subpaths are accepted.
- Accepted audio formats at the OAI layer are `wav` and `mp3` only.

## Foundation Models adapters

`LlamaLanguageModel` adapts a local `LlamaEngine` model to Apple's `LanguageModelSession`. `LlamaServerLanguageModel` is an independent SwiftPM target that adapts a remote llama-server `/chat/completions` endpoint. Both share the `LlamaOpenAICompatible` generation codec, so transcript conversion, tool calls, reasoning deltas, usage, and llama telemetry metadata are handled consistently.

Both adapters accept `extraBody` for llama.cpp-specific request fields such as `timings_per_token` and `return_progress`. Their `supportedReasoningLevels` are derived from the configured `reasoningEffortMapping`, so host apps can offer the `ContextOptions.ReasoningLevel` values that map to enabled llama.cpp thinking, including custom levels such as `.custom("xhigh")`. Shared telemetry keys live in `LlamaTelemetryMetadataKeys` and currently cover `timings` and `prompt_progress`.

## Token counting

After loading a model, use the token counting service to call upstream's OpenAI-compatible input-token routes in-process:

```swift
let count = try await engine.tokenCounting.chatCompletionInputTokens(requestJSON: #"""
{
  "messages": [{"role": "user", "content": "Say hello."}]
}
"""#)
print(count.inputTokens)
```

The returned `TokenCountResult` also carries the raw JSON response in `rawJSON`.

## Multi-Token Prediction (MTP) speculative decoding

For models that ship with an MTP head (e.g. recent Qwen3 MTP variants), enable speculative decoding with `enableMTP: true`:

```swift
var config = ModelConfig(
    modelPath:      URL(fileURLWithPath: "…/Qwen3-mtp.gguf"),
    flashAttention: true,
    enableMTP:      true // self-MTP
)
// External draft head variant (sibling `mtp-*.gguf` file):
// config.mtpDraftModelPath = URL(fileURLWithPath: "…/mtp-qwen3-head.gguf")

try await engine.load(config)
print(engine.isMTPActive)                              // true once wired up
```

## Design notes

### `cpp-httplib` is not linked

Upstream exposes a top-level `LLAMA_HTTPLIB` option (ON by default). When set to OFF:

- `vendor/cpp-httplib` is not added to the build.
- `llama-common` does not link `cpp-httplib`.
- `common/download.cpp` and `common/hf-cache.cpp` compile to inert stub bodies — every HTTP/HF/docker entry point returns an empty/error value without throwing at load time. `server-common.cpp` keeps calling `common_remote_get_content`; it now returns `{0, {}}`, which the existing status check treats as a failed download.

`build-xcframework.sh` passes `-DLLAMA_HTTPLIB=OFF` and omits `libcpp-httplib.a` from the combined archive, so the resulting `LlamaEngineCore.xcframework` contains no HTTP client code. Any `http://` media URL in a chat request will surface as a runtime download failure; pass `file://` or base64 `data:` URLs instead.

The option is guarded so that `LLAMA_BUILD_SERVER=ON` or `LLAMA_BUILD_TESTS=ON` together with `LLAMA_HTTPLIB=OFF` fails configuration — both of those downstream targets genuinely need the HTTP client.
