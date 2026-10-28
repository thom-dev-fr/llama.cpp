#include "runtime_caps.hpp"

namespace llama_engine {

using json = common_json;

json runtime_caps::chat_template_section(const json & caps, bool is_override) {
    json out = json::object();
    out["source"] = is_override ? "override" : "gguf";
    for (const auto & [key, value] : caps.items()) {
        if (key == "supports_reasoning_toggle_known") {
            continue;
        }
        out[key] = value;
    }
    if (!caps.value("supports_reasoning_toggle_known", false)) {
        out["supports_reasoning_toggle"] = nullptr;
    }
    if (!out.contains("reasoning_effort_levels") || !out.at("reasoning_effort_levels").is_array()) {
        out["reasoning_effort_levels"] = nullptr;
    }
    return out;
}

std::string runtime_caps::document(const json & chat_template) {
    return json {
        { "schema_version", schema_version },
        { "chat_template",  chat_template  },
    }.dump();
}

std::string runtime_caps::error_document(const std::string & chat_template_error) {
    return json {
        { "schema_version",      schema_version      },
        { "chat_template",       nullptr             },
        { "chat_template_error", chat_template_error },
    }.dump();
}

} // namespace llama_engine
