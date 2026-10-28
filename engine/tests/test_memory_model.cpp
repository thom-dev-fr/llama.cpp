// Compares llama_engine_measure_memory() (no_alloc) with the breakdown of a
// real context created from the same parameters.
//
// usage: test-llama-engine-memory <model.gguf> [gpu_layers]
// exit code 77 means "skipped" (no model given).

#include "llama_engine.h"
#include "params_translator.hpp"

#include "common.h"
#include "fit.h"
#include "json.h"
#include "llama-cpp.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static int g_total    = 0;
static int g_failures = 0;

#define EXPECT(cond)                                                                \
    do {                                                                            \
        g_total++;                                                                  \
        if (!(cond)) {                                                              \
            g_failures++;                                                           \
            std::fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond);   \
        }                                                                           \
    } while (0)

int main(int argc, char ** argv) {
    if (argc < 2 || argv[1][0] == '\0') {
        std::fprintf(stderr, "SKIP: no model given\n");
        return 77;
    }

    llama_engine_set_log_level(LLAMA_ENGINE_LOG_ERROR);

    llama_engine_config cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.model_path         = argv[1];
    cfg.context_size       = 512;
    cfg.gpu_layers         = argc > 2 ? std::atoi(argv[2]) : 0;
    cfg.parallel_slots     = 1;
    cfg.kv_cache_type      = LLAMA_ENGINE_KV_F16;
    cfg.idle_pause_seconds = -1;

    char * out = nullptr;
    char * err = nullptr;
    EXPECT(llama_engine_measure_memory(&cfg, &out, &err) == LLAMA_ENGINE_OK);
    if (!out) {
        std::fprintf(stderr, "measure failed: %s\n", err ? err : "(no error)");
        llama_engine_free_string(err);
        return 1;
    }
    common_json report = common_json::parse(out);
    llama_engine_free_string(out);

    EXPECT(report.at("effective").at("n_ctx").get<uint32_t>() == 512);
    EXPECT(report.at("complete").get<bool>());
    EXPECT(report.at("required_bytes").at("model").get<uint64_t>() > 0);
    EXPECT(report.at("required_bytes").at("context").get<uint64_t>() > 0);

    // real allocation with the same parameters
    common_params params = llama_engine::params_translator::translate(cfg);
    auto mparams = common_model_params_to_llama(params);
    auto cparams = common_context_params_to_llama(params);
    llama_model_ptr   model(llama_model_load_from_file(cfg.model_path, mparams));
    EXPECT(model != nullptr);
    if (!model) return 1;
    llama_context_ptr ctx(llama_init_from_model(model.get(), cparams));
    EXPECT(ctx != nullptr);
    if (!ctx) return 1;

    uint64_t model_bytes   = 0;
    uint64_t context_bytes = 0;
    uint64_t compute_bytes = 0;
    for (const auto & r : common_memory_breakdown_rows(ctx.get())) {
        model_bytes   += r.model;
        context_bytes += r.context;
        compute_bytes += r.compute;
    }

    const auto & req = report.at("required_bytes");
    std::fprintf(stderr, "measured model=%llu context=%llu compute=%llu, real model=%llu context=%llu compute=%llu\n",
        (unsigned long long) req.at("model").get<uint64_t>(), (unsigned long long) req.at("context").get<uint64_t>(),
        (unsigned long long) req.at("compute").get<uint64_t>(),
        (unsigned long long) model_bytes, (unsigned long long) context_bytes, (unsigned long long) compute_bytes);

    // weights and KV are sized from the same hparams: they must match exactly
    EXPECT(req.at("model").get<uint64_t>()   == model_bytes);
    EXPECT(req.at("context").get<uint64_t>() == context_bytes);
    // the no_alloc reservation over-counts the host compute buffer (about 2x here), so it is an upper bound
    EXPECT(req.at("compute").get<uint64_t>() >= compute_bytes);

    std::printf("\n===== %d / %d passed =====\n", g_total - g_failures, g_total);
    return g_failures == 0 ? 0 : 1;
}
