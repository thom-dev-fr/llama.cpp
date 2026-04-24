# LlamaEngine

Swift/Apple façade over `llama.cpp`'s `server-context`, packaged as an xcframework consumable via SwiftPM.

This folder is a *fork-only* add-on. It does not patch upstream C++ apart from a single guarded block in the root `CMakeLists.txt`. Upstream syncs are performed via `apple/scripts/sync-upstream.sh`.

## Overview

```
apple/
├── llama-engine/        # C++/C API static library wrapping server-context
│   ├── include/         # Public C header (llama_engine.h) + modulemap
│   ├── src/             # Engine core, params translator, task builder, result formatter
│   └── CMakeLists.txt   # Built in-tree via the LLAMA_BUILD_APPLE_ENGINE option
├── Sources/LlamaEngine/ # Swift façade (actor + value types)
├── Tests/cpp/           # Unit tests for the three pure C++ modules
├── scripts/             # build-xcframework.sh, sync-upstream.sh
└── PRD.md               # Product requirements document
```

## Scope (v1)

- Single model lifecycle: `load` / `unload` / `sleep` / `wake`
- Chat completions (OpenAI-compatible JSON in/out)
  - Non-stream: `chatCompletion(requestJSON:) async throws -> String`
  - Stream: `chatCompletionStream(requestJSON:) -> AsyncThrowingStream<String, Error>`
- Tokenize / detokenize
- Metal GPU backend with embedded library
- Thread-safe via Swift `actor`, cooperative cancellation via `Task.cancel()` propagating into `server-context` cancel tasks

Out of scope for v1: embeddings, rerank, multiple concurrent models, image/audio inputs at runtime (the mtmd library is linked but the API to pass media is not yet exposed), and parallel sampling (`n > 1`).

## Build

Prerequisites: Xcode 15+, CMake 3.28+.

```bash
# From the repo root
./apple/scripts/build-xcframework.sh
```

Output: `apple/build/LlamaEngineCore.xcframework` — this is the binary target referenced by the root `Package.swift`.

## Integration (from a sibling app repo)

Assuming your app repository and this fork are checked out next to each other:

```
~/Code/
├── llama.cpp/               # this fork, built with build-xcframework.sh
└── MyApp/
    └── Package.swift
```

In the app's `Package.swift`:

```swift
.package(path: "../llama.cpp")
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

for try await chunk in engine.chatCompletionStream(requestJSON: request) {
    print(chunk)
}

try await engine.unload()
```

## Tests

```bash
cmake -S apple/llama-engine -B build-test \
      -DLLAMA_BUILD_APPLE_ENGINE=ON \
      -DLLAMA_BUILD_APPLE_ENGINE_TESTS=ON \
      -DLLAMA_BUILD_COMMON=ON \
      -DLLAMA_BUILD_TOOLS=OFF
cmake --build build-test --target test-llama-engine-pure
./build-test/tests/test-llama-engine-pure
```

The tests cover the three pure modules (`params_translator`, `task_builder` parse layer, `result_formatter`). Full end-to-end inference tests are deferred — they require a GGUF fixture and are outside v1.

## Upstream sync

```bash
# One-time
git remote add upstream https://github.com/ggml-org/llama.cpp.git

# To pull latest
./apple/scripts/sync-upstream.sh
```

Conflicts, if any, will typically land only in the single guarded block in the root `CMakeLists.txt`.

## Design notes

See `apple/PRD.md` for the full product requirements and design rationale.
