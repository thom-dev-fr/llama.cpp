// Link smoke for the local inference utilities. This deliberately does not use
// arg.h, model acquisition, server-context, or the executable compatibility lib.
#include "common.h"
#include "json-schema-to-grammar.h"
#include "sampling.h"

#include <cstdio>
#include <cstdlib>

static void test_local_init(const char * path) {
    common_params params;
    params.model.path = path;
    params.fit_params = false;
    params.warmup = false;
    params.n_gpu_layers = 0;
    params.n_ctx = 256;
    params.n_batch = 64;
    params.n_ubatch = 64;
    params.cpuparams.n_threads = 2;
    params.cpuparams_batch.n_threads = 2;
    params.sampling.seed = 42;

    auto init = common_init_from_params(params);
    if (params.model.path.empty()) {
        GGML_ASSERT(init->model() == nullptr);
        GGML_ASSERT(init->context() == nullptr);
        return;
    }

    // A supplied fixture must load: never report a missing model as a pass.
    GGML_ASSERT(init->model() != nullptr);
    GGML_ASSERT(init->context() != nullptr);
    auto * ctx = init->context();
    auto * vocab = llama_model_get_vocab(init->model());
    auto tokens = common_tokenize(vocab, "Once upon a time", true, true);
    GGML_ASSERT(!tokens.empty());
    GGML_ASSERT(tokens.size() <= (size_t) params.n_batch);
    GGML_ASSERT(llama_decode(ctx, llama_batch_get_one(tokens.data(), tokens.size())) == 0);

    auto * sampler = init->sampler(0);
    GGML_ASSERT(sampler != nullptr);
    for (int32_t i = 0; i < 4; ++i) {
        auto token = common_sampler_sample(sampler, ctx, -1);
        GGML_ASSERT(token != LLAMA_TOKEN_NULL);
        common_sampler_accept(sampler, token, true);
        GGML_ASSERT(llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0);
    }
    fprintf(stderr, "local model load, tokenization, decode and sampling: OK\n");
}

int main(int argc, char ** argv) {
    if (argc > 2) {
        fprintf(stderr, "usage: %s [local-model.gguf]\n", argv[0]);
        return EXIT_FAILURE;
    }

    const auto schema = common_json::parse(R"({"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]})");
    GGML_ASSERT(!json_schema_to_grammar(schema).empty());

    llama_backend_init();
    test_local_init("");
    if (argc == 2) {
        test_local_init(argv[1]);
    }
    // All model/context/pool resources have been destroyed before backend free.
    llama_backend_free();
    return EXIT_SUCCESS;
}
