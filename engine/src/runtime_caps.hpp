#pragma once

#include "json.h"

#include <string>

namespace llama_engine {

// Builds the JSON documents returned by llama_engine_probe_chat_capabilities()
// and llama_engine_get_capabilities(). Pure: no model, no engine state.
struct runtime_caps {
    static constexpr int schema_version = 1;

    // `caps` is the output of common_chat_templates_get_caps().
    // "supports_reasoning_toggle" is null when the analysis could not decide.
    static common_json chat_template_section(const common_json & caps, bool is_override);

    static std::string document(const common_json & chat_template);
    static std::string error_document(const std::string & chat_template_error);
};

} // namespace llama_engine
