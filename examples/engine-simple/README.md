# llama.cpp/examples/engine-simple

Minimal in-process consumer of the server inference core (`engine/`, CMake target `server-core`). The model runs in the calling process: no HTTP server, no listener, no download and no subprocess. The example streams a chat reply, then tokenizes the prompt.

The core interface (`engine/server-context.h`) is private: it is not installed, and it has no stable API or ABI. It can change with the server code.

## Build

With the full build, the example is built with the server:

```bash
cmake -B build
cmake --build build --target llama-engine-simple
```

Without HTTP, argv parsing, downloads or subprocess support:

```bash
cmake -B build-local -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_SERVER_CORE=ON -DLLAMA_SUBPROCESS=OFF
cmake --build build-local --target llama-engine-simple
```

## Run

```bash
./build/bin/llama-engine-simple -m model.gguf -p "Tell me a short story." -n 64
./build/bin/llama-engine-simple -m model.gguf --mmproj mmproj.gguf --image image.jpg -p "Describe the image."
```

Model and projector paths must be local files. The example sets `n_ctx = 4096` (change it with `-c`) and `n_parallel = 1`. Other settings keep the `common_params` defaults. It returns a nonzero status for invalid arguments, load failures and inference errors.

## Use of the core

- Fill `common_params` and call `postprocess_cpu_params()` for the thread settings, as argv parsing does.
- `load_model()`, then run `start_loop()` on a thread. `terminate()` has no effect before `start_loop()` runs, so the example waits for one answer from the loop before it stops it.
- For each request, get a `server_response_reader`, build the tasks with `prepare_*()`, post them, and read the results with `next()` or `wait_for_all()`. Results serialize with `to_json()` to the same JSON as the HTTP API.
- Destroy the readers before the loop is stopped and before the `server_context`.
- Remote media URLs are rejected unless the host sets a fetcher with `set_media_fetcher()`. Video and WebP inputs need `MTMD_VIDEO`, which uses a subprocess.

## Tests

`tests/test-server-core.cpp` uses the core in the same way. ctest runs the `load` case (no model) and, in the full build, the `lifecycle` case with the downloaded `stories15M-q4_0.gguf`. The other cases need larger models and are not registered:

| Case | Model |
| --- | --- |
| `chat`, `tools`, `schema` | chat model with a jinja template and tool support |
| `reasoning` | chat model that can think, with `enable_thinking` |
| `vision` | vision model and projector, `--media tools/mtmd/test-1.jpeg` |
| `audio` | audio model and projector, `--media tools/mtmd/test-2.mp3` |
| `embeddings` | embedding model, e.g. `bert-bge-small` |
| `rerank` | reranker, e.g. `jina-reranker-v1-tiny-en` |

```bash
./build/bin/test-server-core tools -m model.gguf
./build/bin/test-server-core vision -m model.gguf --mmproj mmproj.gguf --media tools/mtmd/test-1.jpeg
```

The cases use the CPU by default; add `-ngl 99` to offload.
