#pragma once

#include "llama_engine.h"

#include "common.h"
#include "fit.h"
#include "json.h"

#include <string>
#include <vector>

namespace llama_engine {

// Native memory measurement of a config, see llama_engine_measure_memory().
struct memory_measure {
    static constexpr int schema_version = 1;

    struct measured {
        std::vector<common_memory_breakdown_row> rows;
        uint32_t n_ctx       = 0;
        uint32_t n_ctx_train = 0;
    };

    // Measures `cfg` with common_fit_measure(): the model and its context are
    // created with no_alloc, nothing is loaded. Measurements are serialised
    // because the helper swaps the global llama log callback.
    static llama_engine_status measure(const llama_engine_config & cfg,
                                       std::string &               out_json,
                                       std::string &               error);

    // Pure: builds the report from the measured rows. Exposed for unit tests.
    static common_json report(const common_params & params,
                              const llama_model_params & mparams,
                              const llama_context_params & cparams,
                              const measured & m);
};

} // namespace llama_engine
