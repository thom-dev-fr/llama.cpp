#pragma once

#include "llama_engine.h"

#include "common.h"

#include <nlohmann/json.hpp>

#include <string>

namespace llama_engine {

// Translates a public llama_engine_config struct into a common_params
// suitable for common_init_from_params / server_context::load_model.
//
// Pure function: no state, no threads, no side effects beyond parsing extra_json.
// Throws std::invalid_argument on validation errors.
struct params_translator {
    static common_params translate(const llama_engine_config & cfg);

    // Exposed for unit tests.
    static ggml_type map_kv_cache_type(llama_engine_kv_type t);
    static void apply_extra_json(common_params & params, const nlohmann::ordered_json & extra);
};

} // namespace llama_engine
