# llama-engine

`llama-engine` is a small embeddable C API around llama.cpp server internals. It is intended for apps and language bindings that need local chat completion without running the HTTP server.

## What it provides

- Model lifecycle: load, unload, pause, and resume.
- Chat completions through OpenAI-compatible JSON requests.
- Streaming chat completions with cancellation.
- Tokenize, detokenize, and input token counting helpers.
- Lightweight GGUF capability and metadata probing.
- Optional multimodal projector and MTP speculative decoding support.

## Layout

- `include/llama_engine.h`: public C API.
- `src/`: C++ implementation and adapters to common/server code.
- `tests/`: unit tests for the engine components.

## Building

From the repository root:

```sh
cmake -B build -DLLAMA_BUILD_ENGINE=ON
cmake --build build --target llama-engine
```

To build and run the tests:

```sh
cmake -S . -B build-engine-tests \
  -DLLAMA_BUILD_ENGINE=ON \
  -DLLAMA_BUILD_ENGINE_TESTS=ON \
  -DLLAMA_BUILD_COMMON=ON \
  -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_HTTPLIB=OFF
cmake --build build-engine-tests --target test-llama-engine-pure test-llama-engine-capi
ctest --test-dir build-engine-tests -L engine --output-on-failure --no-tests=error
```

Tests:

- `llama-engine-pure`: unit tests of the internal modules, no model.
- `llama-engine-capi-cpu` (and `llama-engine-capi-metal` with Metal): end-to-end test of the public C API, written in C. It loads `tinyllamas/stories15M-q4_0.gguf`, downloaded by the `llama-engine-download-model` fixture. Pass `-DLLAMA_ENGINE_TEST_MODEL=/path/to/model.gguf` to use a local file and skip the download. Without a model the test exits with code 77 and CTest reports it as skipped.

You can also run the test binaries directly:

```sh
./build-engine-tests/bin/test-llama-engine-pure
./build-engine-tests/bin/test-llama-engine-capi /path/to/stories15M-q4_0.gguf [gpu_layers]
```

CI runs these tests, the macOS XCFramework build and the Swift package tests in `.github/workflows/engine.yml`.

## Swift binding example

An Apple SwiftPM binding is available in `examples/apple/swift-llama-engine`.
Build its XCFramework first:

```sh
./examples/apple/swift-llama-engine/scripts/build-xcframework.sh
```

Then add it to an app package:

```swift
// Package.swift
.package(name: "LlamaEngine", path: "../llama.cpp/examples/apple/swift-llama-engine")

// Target dependency
.product(name: "LlamaEngine", package: "LlamaEngine")
```

Minimal usage:

```swift
import Foundation
import LlamaEngine

let engine = LlamaEngine()
try await engine.load(ModelConfig(
    modelPath: URL(fileURLWithPath: "/path/to/model.gguf"),
    gpuLayers: -1,
    flashAttention: true
))

let response = try await engine.chatCompletion(requestJSON: #"""
{
  "messages": [{"role": "user", "content": "Say hello."}]
}
"""#)
print(response)

try await engine.unload()
```
