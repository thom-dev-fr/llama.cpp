#pragma once

#include "llama_engine.h"

#include "common.h"
#include "fit.h"
#include "json.h"

#include <optional>
#include <string>
#include <vector>

namespace llama_engine {

// Native memory measurement of a config, see llama_engine_measure_memory().
struct memory_measure {
    static constexpr int schema_version = 2;

    struct measured {
        std::vector<common_memory_breakdown_row> rows;
        uint32_t n_ctx       = 0;
        uint32_t n_ctx_train = 0;

        // measured apart from the rows, empty when the config has none or the measurement failed
        std::optional<uint64_t> projector;
        std::optional<uint64_t> mtp_draft;
        std::string projector_error;
        std::string mtp_draft_error;
    };

    // Measures `cfg` with common_fit_measure(): the model and its context are
    // created with no_alloc, nothing is loaded. The multimodal projector is
    // measured with mtmd_get_memory_usage() and the MTP draft context like the
    // draft context of the load path. Measurements are serialised because the
    // helpers swap the global llama and mtmd log callbacks.
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
