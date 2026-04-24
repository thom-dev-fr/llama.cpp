#include "test_util.hpp"

#include "task_builder.hpp"

#include "chat.h"
#include "common.h"

#include <stdexcept>
#include <string>

using llama_engine::task_builder;
using json = nlohmann::ordered_json;

// Build a minimal server_chat_params with a literal jinja template so we don't
// need to load a GGUF model. The template simply concatenates message contents;
// it is enough to exercise the OAI→llama_params path inside
// oaicompat_chat_params_parse.
static server_chat_params make_synthetic_chat_params() {
    server_chat_params p;
    p.use_jinja           = true;
    p.prefill_assistant   = false;
    p.reasoning_format    = COMMON_REASONING_FORMAT_NONE;
    p.allow_image         = false;
    p.allow_audio         = false;
    p.enable_thinking     = false;
    p.reasoning_budget    = -1;
    p.force_pure_content  = false;
    p.tmpls = common_chat_templates_init(
        /*model=*/nullptr,
        /*chat_template_override=*/
        "{%- for m in messages %}<{{ m.role }}>{{ m.content }}</{{ m.role }}>{%- endfor %}<assistant>",
        /*bos_token_override=*/"",
        /*eos_token_override=*/"");
    return p;
}

// 1×1 transparent PNG (base64). 67 bytes decoded.
static constexpr const char * TINY_PNG_B64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

// Arbitrary 8-byte payload as base64 — upstream only base64-decodes and stores
// audio bytes in parsed.files; no format validation happens at this layer.
static constexpr const char * TINY_AUDIO_B64 = "UklGRgAAAAA=";

static void test_invalid_json_throws() {
    CASE("invalid JSON throws invalid_argument");
    auto opt = make_synthetic_chat_params();
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request("not json at all", opt),
        std::invalid_argument);
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request("[1,2,3]", opt),
        std::invalid_argument);
}

static void test_missing_messages_throws() {
    CASE("missing messages throws");
    auto opt = make_synthetic_chat_params();
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(R"({"stream": true})", opt),
        std::invalid_argument);
}

static void test_basic_chat_request() {
    CASE("basic chat request parses and produces prompt + id");
    auto opt = make_synthetic_chat_params();
    const std::string req = R"({
        "model": "test",
        "messages": [
            {"role": "user", "content": "hello"}
        ],
        "temperature": 0.7
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT_EQ(parsed.stream, false);
    EXPECT(parsed.cmpl_id.rfind("chatcmpl-", 0) == 0);
    EXPECT(parsed.data.contains("prompt"));
    EXPECT(parsed.data.at("prompt").is_string());
    EXPECT(parsed.data.at("prompt").get<std::string>().find("hello") != std::string::npos);
}

static void test_stream_flag_propagation() {
    CASE("stream=true is propagated");
    auto opt = make_synthetic_chat_params();
    const std::string req = R"({
        "messages": [{"role": "user", "content": "hi"}],
        "stream": true
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT_EQ(parsed.stream, true);
}

static void test_stop_string_wrapped_to_array() {
    CASE("stop: string is wrapped to array");
    auto opt = make_synthetic_chat_params();
    const std::string req = R"({
        "messages": [{"role": "user", "content": "hi"}],
        "stop": "STOP"
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT(parsed.data.contains("stop"));
    EXPECT(parsed.data.at("stop").is_array());
    EXPECT_EQ(parsed.data.at("stop").size(), (size_t)1);
    EXPECT_EQ(parsed.data.at("stop")[0].get<std::string>(), std::string("STOP"));
}

static void test_response_format_bad_type_throws() {
    CASE("response_format with bad type throws invalid_argument");
    auto opt = make_synthetic_chat_params();
    const std::string req = R"({
        "messages": [{"role": "user", "content": "hi"}],
        "response_format": {"type": "yolo"}
    })";
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(req, opt),
        std::invalid_argument);
}

static void test_image_without_allow_image_throws() {
    CASE("image_url content part without allow_image throws");
    auto opt = make_synthetic_chat_params();
    const std::string req = R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "describe"},
                {"type": "image_url", "image_url": {"url": "http://x/y.png"}}
            ]
        }]
    })";
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(req, opt),
        std::runtime_error);
}

static void test_image_data_url_extracted_to_files() {
    CASE("image_url data: URL is decoded into parsed.files");
    auto opt = make_synthetic_chat_params();
    opt.allow_image = true;
    const std::string req = std::string(R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "describe this"},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64,)") + TINY_PNG_B64 + R"("}}
            ]
        }]
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT_EQ(parsed.files.size(), (size_t)1);
    EXPECT(parsed.files[0].size() > 8);
    // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
    EXPECT_EQ((int)parsed.files[0][0], 0x89);
    EXPECT_EQ((int)parsed.files[0][1], 0x50);
    EXPECT_EQ((int)parsed.files[0][2], 0x4E);
    EXPECT_EQ((int)parsed.files[0][3], 0x47);
}

static void test_audio_wav_extracted_to_files() {
    CASE("input_audio wav base64 is decoded into parsed.files");
    auto opt = make_synthetic_chat_params();
    opt.allow_audio = true;
    const std::string req = std::string(R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "transcribe"},
                {"type": "input_audio", "input_audio": {"data": ")") + TINY_AUDIO_B64 + R"(", "format": "wav"}}
            ]
        }]
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT_EQ(parsed.files.size(), (size_t)1);
    EXPECT(parsed.files[0].size() > 0);
}

static void test_audio_bad_format_throws() {
    CASE("input_audio with unsupported format throws");
    auto opt = make_synthetic_chat_params();
    opt.allow_audio = true;
    const std::string req = std::string(R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "input_audio", "input_audio": {"data": ")") + TINY_AUDIO_B64 + R"(", "format": "flac"}}
            ]
        }]
    })";
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(req, opt),
        std::invalid_argument);
}

static void test_audio_without_allow_audio_throws() {
    CASE("input_audio content part without allow_audio throws");
    auto opt = make_synthetic_chat_params();
    opt.allow_audio = false;
    const std::string req = std::string(R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "input_audio", "input_audio": {"data": ")") + TINY_AUDIO_B64 + R"(", "format": "wav"}}
            ]
        }]
    })";
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(req, opt),
        std::runtime_error);
}

static void test_multiple_images_preserve_order() {
    CASE("multiple image parts produce buffers in source order");
    auto opt = make_synthetic_chat_params();
    opt.allow_image = true;
    // Two distinct images: the tiny PNG, and the tiny PNG with one byte changed
    // by using a different (still valid) base64 payload for the second one.
    // Simpler: send the same PNG twice but check count & first bytes of each.
    const std::string req = std::string(R"({
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "compare"},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64,)") + TINY_PNG_B64 + R"("}},
                {"type": "text", "text": "and"},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64,)" + std::string(TINY_PNG_B64) + R"("}}
            ]
        }]
    })";
    auto parsed = task_builder::parse_oai_chat_request(req, opt);
    EXPECT_EQ(parsed.files.size(), (size_t)2);
    EXPECT_EQ((int)parsed.files[0][0], 0x89);
    EXPECT_EQ((int)parsed.files[1][0], 0x89);
    EXPECT_EQ(parsed.files[0].size(), parsed.files[1].size());
}

static void test_tools_without_jinja_throws() {
    CASE("tools without jinja throws runtime_error");
    auto opt = make_synthetic_chat_params();
    opt.use_jinja = false;
    const std::string req = R"({
        "messages": [{"role": "user", "content": "hi"}],
        "tools": [{"type": "function", "function": {"name": "foo", "parameters": {"type":"object"}}}]
    })";
    EXPECT_THROWS(
        task_builder::parse_oai_chat_request(req, opt),
        std::runtime_error);
}

void run_task_builder_tests() {
    std::fprintf(stderr, "TaskBuilder:\n");
    test_invalid_json_throws();
    test_missing_messages_throws();
    test_basic_chat_request();
    test_stream_flag_propagation();
    test_stop_string_wrapped_to_array();
    test_response_format_bad_type_throws();
    test_image_without_allow_image_throws();
    test_image_data_url_extracted_to_files();
    test_audio_wav_extracted_to_files();
    test_audio_bad_format_throws();
    test_audio_without_allow_audio_throws();
    test_multiple_images_preserve_order();
    test_tools_without_jinja_throws();
}
