# llama-engine

`llama-engine` is a small embeddable C API around llama.cpp server internals. It is intended for apps and language bindings that need local chat completion without running the HTTP server.

## What it provides

- Model lifecycle: load, unload, pause, and resume.
- Chat completion through OpenAI-compatible JSON requests.
- Streaming chat completions with cancellation.
- Tokenize, detokenize, and chat token counting helpers.
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

To build and run the unit tests:

```sh
cmake -S . -B build-engine-tests \
  -DLLAMA_BUILD_ENGINE=ON \
  -DLLAMA_BUILD_ENGINE_TESTS=ON \
  -DLLAMA_BUILD_COMMON=ON \
  -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_TOOLS=OFF
cmake --build build-engine-tests --target test-llama-engine-pure
ctest --test-dir build-engine-tests --output-on-failure -R llama-engine-pure
```

You can also run the test binary directly:

```sh
./build-engine-tests/bin/test-llama-engine-pure
```
