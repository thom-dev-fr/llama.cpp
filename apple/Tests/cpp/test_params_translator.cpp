#include "test_util.hpp"

#include "params_translator.hpp"
#include "llama_engine.h"
#include "llama.h"

#include <stdexcept>

using llama_engine::params_translator;

static llama_engine_config make_minimal_cfg() {
    llama_engine_config cfg{};
    cfg.model_path = "/tmp/fake.gguf";
    cfg.context_size = 0;
    cfg.gpu_layers = -1;
    cfg.parallel_slots = 1;
    cfg.cpu_threads = 0;
    cfg.seed = 0xFFFFFFFFu;
    cfg.kv_cache_type = LLAMA_ENGINE_KV_F16;
    cfg.idle_sleep_seconds = -1;
    cfg.use_mmap = true;
    return cfg;
}

static void test_minimal_config() {
    CASE("minimal config produces usable common_params");
    auto cfg = make_minimal_cfg();
    auto p = params_translator::translate(cfg);
    EXPECT_EQ(p.model.path, std::string("/tmp/fake.gguf"));
    EXPECT_EQ(p.n_gpu_layers, -1);
    EXPECT_EQ(p.n_parallel, 1);
    EXPECT_EQ(p.use_mmap, true);
    EXPECT(p.cpuparams.n_threads > 0);
}

static void test_missing_model_path_throws() {
    CASE("missing model_path throws invalid_argument");
    auto cfg = make_minimal_cfg();
    cfg.model_path = nullptr;
    EXPECT_THROWS(params_translator::translate(cfg), std::invalid_argument);

    cfg.model_path = "";
    EXPECT_THROWS(params_translator::translate(cfg), std::invalid_argument);
}

static void test_kv_type_mapping() {
    CASE("kv_cache_type maps to ggml_type");
    EXPECT_EQ(params_translator::map_kv_cache_type(LLAMA_ENGINE_KV_F16), GGML_TYPE_F16);
    EXPECT_EQ(params_translator::map_kv_cache_type(LLAMA_ENGINE_KV_Q8_0), GGML_TYPE_Q8_0);
    EXPECT_EQ(params_translator::map_kv_cache_type(LLAMA_ENGINE_KV_BF16), GGML_TYPE_BF16);
    EXPECT_EQ(params_translator::map_kv_cache_type(LLAMA_ENGINE_KV_IQ4_NL), GGML_TYPE_IQ4_NL);
}

static void test_flash_attention_enum() {
    CASE("flash_attention boolean maps to flash_attn_type");
    auto cfg = make_minimal_cfg();
    cfg.flash_attention = true;
    auto p = params_translator::translate(cfg);
    EXPECT_EQ(p.flash_attn_type, LLAMA_FLASH_ATTN_TYPE_ENABLED);

    cfg.flash_attention = false;
    p = params_translator::translate(cfg);
    EXPECT_EQ(p.flash_attn_type, LLAMA_FLASH_ATTN_TYPE_AUTO);
}

static void test_context_size_override() {
    CASE("context_size > 0 overrides n_ctx, 0 leaves default");
    auto cfg = make_minimal_cfg();
    cfg.context_size = 8192;
    auto p = params_translator::translate(cfg);
    EXPECT_EQ(p.n_ctx, 8192);

    cfg.context_size = 0;
    p = params_translator::translate(cfg);
    EXPECT_EQ(p.n_ctx, 0);
}

static void test_extra_json_valid_keys() {
    CASE("extra_json applies known keys and ignores unknown ones");
    auto cfg = make_minimal_cfg();
    cfg.extra_json = R"({"n_batch": 1024, "n_ubatch": 256, "unknown_key": 42, "use_jinja": false})";
    auto p = params_translator::translate(cfg);
    EXPECT_EQ(p.n_batch, 1024);
    EXPECT_EQ(p.n_ubatch, 256);
    EXPECT_EQ(p.use_jinja, false);
}

static void test_extra_json_invalid() {
    CASE("extra_json that isn't an object throws invalid_argument");
    auto cfg = make_minimal_cfg();
    cfg.extra_json = R"([1, 2, 3])";
    EXPECT_THROWS(params_translator::translate(cfg), std::invalid_argument);

    cfg.extra_json = R"(not json)";
    EXPECT_THROWS(params_translator::translate(cfg), std::invalid_argument);
}

static void test_extra_json_media_path() {
    CASE("extra_json media_path normalises trailing slash");
    auto cfg = make_minimal_cfg();
    cfg.extra_json = R"({"media_path": "/tmp/media"})";
    auto p = params_translator::translate(cfg);
    EXPECT_EQ(p.media_path, std::string("/tmp/media/"));

    cfg.extra_json = R"({"media_path": "/tmp/media/"})";
    p = params_translator::translate(cfg);
    EXPECT_EQ(p.media_path, std::string("/tmp/media/"));

    cfg.extra_json = R"({"media_path": ""})";
    p = params_translator::translate(cfg);
    EXPECT_EQ(p.media_path, std::string(""));
}

static void test_cpu_threads_auto() {
    CASE("cpu_threads <= 0 uses hardware concurrency");
    auto cfg = make_minimal_cfg();
    cfg.cpu_threads = 0;
    auto p = params_translator::translate(cfg);
    EXPECT(p.cpuparams.n_threads > 0);
    EXPECT_EQ(p.cpuparams.n_threads, p.cpuparams_batch.n_threads);
}

void run_params_translator_tests() {
    std::fprintf(stderr, "ParamsTranslator:\n");
    test_minimal_config();
    test_missing_model_path_throws();
    test_kv_type_mapping();
    test_flash_attention_enum();
    test_context_size_override();
    test_extra_json_valid_keys();
    test_extra_json_invalid();
    test_extra_json_media_path();
    test_cpu_threads_auto();
}
