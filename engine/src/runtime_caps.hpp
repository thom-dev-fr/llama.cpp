#pragma once

#include "json.h"

#include <string>
#include <vector>

namespace llama_engine {

// Builds the JSON documents returned by llama_engine_probe_chat_capabilities()
// and llama_engine_get_capabilities(). Pure: no model, no engine state.
struct runtime_caps {
    static constexpr int schema_version = 1;

    // `caps` is the output of common_chat_templates_get_caps().
    // "supports_reasoning_toggle" is null when the analysis could not decide.
    static common_json chat_template_section(const common_json & caps, bool is_override);

    // Values copied from server_context_meta after a load.
    struct runtime_flags {
        bool has_mtmd             = false;
        bool inp_image            = false;
        bool inp_audio            = false;
        bool inp_video            = false;
        bool cap_chat             = false;
        bool cap_tts              = false;
        bool audio_stream         = false;
        bool audio_gen_spk_ref    = false;
        std::vector<std::string> output_modalities;
    };

    // What the loaded model and build can do, whatever the engine API exposes.
    static common_json model_capabilities_section(const runtime_flags & f);
    // What the engine C API can run with this configuration. False for what it
    // does not expose yet (speech generation, transcription, realtime).
    static common_json engine_operations_section(const runtime_flags & f);

    static std::string document(const common_json & chat_template);
    static std::string runtime_document(const common_json & chat_template, const runtime_flags & f);
    static std::string error_document(const std::string & chat_template_error);
};

} // namespace llama_engine
