#include "test_util.hpp"

#include "caps_probe.hpp"
#include "runtime_caps.hpp"
#include "llama_engine.h"

#include <cstring>
#include <string>

using llama_engine::runtime_caps;
using json = common_json;

static void test_chat_template_section_known_toggle() {
    CASE("chat_template section keeps a known toggle and the effort levels");
    json caps = json::parse(R"({
        "supports_tool_calls": true,
        "supports_reasoning": true,
        "supports_reasoning_toggle": false,
        "supports_reasoning_toggle_known": true,
        "reasoning_effort_levels": ["low", "high", "max"]
    })");
    json out = runtime_caps::chat_template_section(caps, false);
    EXPECT_EQ(out.at("source").get<std::string>(), std::string("gguf"));
    EXPECT(out.at("supports_tool_calls").get<bool>());
    EXPECT(out.at("supports_reasoning_toggle").is_boolean());
    EXPECT(!out.at("supports_reasoning_toggle").get<bool>());
    EXPECT(!out.contains("supports_reasoning_toggle_known"));
    EXPECT_EQ(out.at("reasoning_effort_levels").dump(), std::string(R"(["low","high","max"])"));
}

static void test_chat_template_section_unknown_values() {
    CASE("unknown toggle and missing levels become null, empty levels stay empty");
    json caps = json::parse(R"({"supports_reasoning": true, "supports_reasoning_toggle": false})");
    json out = runtime_caps::chat_template_section(caps, true);
    EXPECT_EQ(out.at("source").get<std::string>(), std::string("override"));
    EXPECT(out.at("supports_reasoning_toggle").is_null());
    EXPECT(out.at("reasoning_effort_levels").is_null());

    caps = json::parse(R"({"supports_reasoning_toggle_known": true, "supports_reasoning_toggle": true, "reasoning_effort_levels": []})");
    out = runtime_caps::chat_template_section(caps, false);
    EXPECT(out.at("supports_reasoning_toggle").get<bool>());
    EXPECT(out.at("reasoning_effort_levels").is_array());
    EXPECT_EQ(out.at("reasoning_effort_levels").size(), (size_t) 0);
}

static void test_documents() {
    CASE("documents carry the schema version");
    json doc = json::parse(runtime_caps::document(json::object()));
    EXPECT_EQ(doc.at("schema_version").get<int>(), 1);
    EXPECT(doc.at("chat_template").is_object());

    doc = json::parse(runtime_caps::error_document("bad template"));
    EXPECT(doc.at("chat_template").is_null());
    EXPECT_EQ(doc.at("chat_template_error").get<std::string>(), std::string("bad template"));
}

static llama_engine_config vocab_config(const char * path) {
    llama_engine_config cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.model_path         = path;
    cfg.kv_cache_type      = LLAMA_ENGINE_KV_F16;
    cfg.idle_pause_seconds = -1;
    return cfg;
}

static void test_probe_chat_capabilities() {
    CASE("probe_chat_capabilities on a vocab-only GGUF");
    std::string out;
    std::string err;

    auto cfg = vocab_config(LLAMA_ENGINE_TEST_VOCAB);
    EXPECT_EQ((int) llama_engine::probe_chat_capabilities(cfg, out, err), (int) LLAMA_ENGINE_OK);
    json doc = json::parse(out);
    EXPECT_EQ(doc.at("schema_version").get<int>(), 1);
    EXPECT(doc.at("chat_template").is_object());
    EXPECT_EQ(doc.at("chat_template").at("source").get<std::string>(), std::string("gguf"));
    EXPECT(doc.at("chat_template").at("reasoning_effort_levels").is_array());

    cfg.chat_template_override = "chatml";
    EXPECT_EQ((int) llama_engine::probe_chat_capabilities(cfg, out, err), (int) LLAMA_ENGINE_OK);
    doc = json::parse(out);
    EXPECT_EQ(doc.at("chat_template").at("source").get<std::string>(), std::string("override"));
    EXPECT(!doc.at("chat_template").at("supports_tool_calls").get<bool>());

    cfg.chat_template_override = "{% if %}";
    EXPECT_EQ((int) llama_engine::probe_chat_capabilities(cfg, out, err), (int) LLAMA_ENGINE_OK);
    doc = json::parse(out);
    EXPECT(doc.at("chat_template").is_null());
    EXPECT(!doc.at("chat_template_error").get<std::string>().empty());
}

static void test_probe_chat_capabilities_errors() {
    CASE("probe_chat_capabilities hard errors");
    std::string out;
    std::string err;

    auto cfg = vocab_config("/nonexistent/model.gguf");
    EXPECT_EQ((int) llama_engine::probe_chat_capabilities(cfg, out, err), (int) LLAMA_ENGINE_ERR_INVALID_ARG);
    EXPECT(out.empty());
    EXPECT(!err.empty());

    cfg = vocab_config(nullptr);
    EXPECT_EQ((int) llama_engine::probe_chat_capabilities(cfg, out, err), (int) LLAMA_ENGINE_ERR_INVALID_ARG);

    char * json_out = nullptr;
    char * err_out  = nullptr;
    EXPECT_EQ((int) llama_engine_probe_chat_capabilities(nullptr, &json_out, &err_out), (int) LLAMA_ENGINE_ERR_INVALID_ARG);
    EXPECT(json_out == nullptr);
    EXPECT_EQ((int) llama_engine_get_capabilities(nullptr, &json_out), (int) LLAMA_ENGINE_ERR_INVALID_ARG);
}

static json runtime_doc(const runtime_caps::runtime_flags & f) {
    return json::parse(runtime_caps::runtime_document(json::object(), f));
}

static void test_runtime_sections_text_only() {
    CASE("text-only model: chat operations only");
    runtime_caps::runtime_flags f;
    f.cap_chat          = true;
    f.output_modalities = { "text" };
    json doc = runtime_doc(f);
    const auto & m  = doc.at("model_capabilities");
    const auto & op = doc.at("engine_operations");
    EXPECT(m.at("chat").get<bool>());
    EXPECT(!m.at("input_image").get<bool>());
    EXPECT(!m.at("multimodal_projector").get<bool>());
    EXPECT_EQ(m.at("output_modalities").dump(), std::string(R"(["text"])"));
    EXPECT(op.at("chat_completion").get<bool>());
    EXPECT(op.at("tokenize").get<bool>());
    EXPECT(!op.at("image_input").get<bool>());
    EXPECT(!op.at("realtime").get<bool>());
}

static void test_runtime_sections_multimodal_inputs() {
    CASE("vision and audio inputs become chat operations, video only when built");
    runtime_caps::runtime_flags f;
    f.has_mtmd  = true;
    f.cap_chat  = true;
    f.inp_image = true;
    f.inp_audio = true;
    json doc = runtime_doc(f);
    EXPECT(doc.at("engine_operations").at("image_input").get<bool>());
    EXPECT(doc.at("engine_operations").at("audio_input").get<bool>());
    EXPECT(!doc.at("engine_operations").at("video_input").get<bool>());
    EXPECT(!doc.at("model_capabilities").at("input_video").get<bool>());
}

static void test_runtime_sections_audio_models() {
    CASE("TTS, transcription and conversation models are not engine operations yet");
    runtime_caps::runtime_flags tts;
    tts.has_mtmd          = true;
    tts.cap_tts           = true;
    tts.audio_gen_spk_ref = true;
    tts.output_modalities = { "audio" };
    json doc = runtime_doc(tts);
    EXPECT(doc.at("model_capabilities").at("audio_generation").get<bool>());
    EXPECT(doc.at("model_capabilities").at("audio_speaker_reference").get<bool>());
    EXPECT(!doc.at("model_capabilities").at("chat").get<bool>());
    EXPECT(!doc.at("engine_operations").at("chat_completion").get<bool>());
    EXPECT(!doc.at("engine_operations").at("speech_generation").get<bool>());

    runtime_caps::runtime_flags asr;
    asr.has_mtmd     = true;
    asr.inp_audio    = true;
    asr.audio_stream = true;
    doc = runtime_doc(asr);
    EXPECT(doc.at("model_capabilities").at("audio_stream").get<bool>());
    EXPECT(!doc.at("model_capabilities").at("realtime_conversation").get<bool>());
    EXPECT(!doc.at("engine_operations").at("audio_input").get<bool>());
    EXPECT(!doc.at("engine_operations").at("transcription").get<bool>());

    runtime_caps::runtime_flags conv = asr;
    conv.cap_chat = true;
    doc = runtime_doc(conv);
    EXPECT(doc.at("model_capabilities").at("realtime_conversation").get<bool>());
    EXPECT(!doc.at("engine_operations").at("realtime").get<bool>());
}

void run_runtime_caps_tests() {
    std::fprintf(stderr, "RuntimeCaps:\n");
    test_chat_template_section_known_toggle();
    test_chat_template_section_unknown_values();
    test_documents();
    test_probe_chat_capabilities();
    test_probe_chat_capabilities_errors();
    test_runtime_sections_text_only();
    test_runtime_sections_multimodal_inputs();
    test_runtime_sections_audio_models();
}
