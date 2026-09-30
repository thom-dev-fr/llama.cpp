# llama.cpp/examples/engine-simple

Minimal consumer of the embeddable inference engine (`include/llama-engine.h`,
CMake target `llama-engine`): the model runs in the calling process, without
`llama-server` or a port. The example streams a chat reply, then counts the
tokens of the prompt with a non-streaming request.

```bash
./llama-engine-simple -m ./models/model.gguf -p "Tell me a short story." -n 64
```

The interface is described in [docs/design/embedded-inference-engine-api.md](../../docs/design/embedded-inference-engine-api.md).
The same source is built as `test-engine-example` by the tests, including in
builds without the examples, the executables or HTTP support.
