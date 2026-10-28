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

json runtime_caps::model_capabilities_section(const runtime_flags & f) {
    return json {
        { "chat",                    f.cap_chat              },
        { "input_image",             f.inp_image             },
        { "input_audio",             f.inp_audio             },
        { "input_video",             f.inp_video             },
        { "output_modalities",       f.output_modalities     },
        { "audio_generation",        f.cap_tts               },
        { "audio_speaker_reference", f.audio_gen_spk_ref     },
        // realtime transcription; with chat the server holds a voice conversation
        { "audio_stream",            f.audio_stream          },
        { "realtime_conversation",   f.audio_stream && f.cap_chat },
        { "multimodal_projector",    f.has_mtmd              },
    };
}

json runtime_caps::engine_operations_section(const runtime_flags & f) {
    return json {
        { "chat_completion",        f.cap_chat              },
        { "chat_completion_stream", f.cap_chat              },
        { "count_chat_tokens",      f.cap_chat              },
        { "tokenize",               true                    },
        { "image_input",            f.cap_chat && f.inp_image },
        { "audio_input",            f.cap_chat && f.inp_audio },
        { "video_input",            f.cap_chat && f.inp_video },
        { "speech_generation",      false                   },
        { "transcription",          false                   },
        { "realtime",               false                   },
    };
}

std::string runtime_caps::runtime_document(const json & chat_template, const runtime_flags & f) {
    return json {
        { "schema_version",     schema_version                },
        { "chat_template",      chat_template                 },
        { "model_capabilities", model_capabilities_section(f) },
        { "engine_operations",  engine_operations_section(f)  },
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
