// End-to-end test of the public C API against a small real model.
// Written in C on purpose: it checks that llama_engine.h is valid C and that
// a C program links against the full static library.
//
// usage: test-llama-engine-capi <model.gguf> [gpu_layers]
// exit code 77 means "skipped" (no model given), see SKIP_RETURN_CODE in CMake.

#include "llama_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_total    = 0;
static int g_failures = 0;

#define EXPECT(cond)                                                            \
    do {                                                                        \
        g_total++;                                                              \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond);    \
        }                                                                       \
    } while (0)

#define EXPECT_STATUS(expr, want)                                               \
    do {                                                                        \
        g_total++;                                                              \
        llama_engine_status _st = (expr);                                       \
        if (_st != (want)) {                                                    \
            g_failures++;                                                       \
            fprintf(stderr, "FAIL: %s:%d: %s returned %d, want %d\n",           \
                    __FILE__, __LINE__, #expr, (int) _st, (int) (want));        \
        }                                                                       \
    } while (0)

static const char * k_chat_request =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"Once upon a time\"}],"
    "\"max_tokens\":8,\"temperature\":0}";

static const char * k_stream_request =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"Once upon a time\"}],"
    "\"max_tokens\":8,\"temperature\":0,\"stream\":true}";

static void test_probe(const char * model_path) {
    fprintf(stderr, "  * probe model info\n");
    llama_engine_model_info info;
    char * err = NULL;
    EXPECT_STATUS(llama_engine_probe_model_info(model_path, NULL, &info, &err), LLAMA_ENGINE_OK);
    EXPECT(err == NULL);
    EXPECT(info.architecture != NULL && strcmp(info.architecture, "llama") == 0);
    EXPECT(info.metadata.has_block_count && info.metadata.block_count > 0);
    EXPECT(!info.has_projector);
    llama_engine_free_model_info(&info);
    llama_engine_free_model_info(&info); // must be safe twice

    EXPECT_STATUS(llama_engine_probe_model_info("/nonexistent/model.gguf", NULL, &info, &err), LLAMA_ENGINE_ERR_INVALID_ARG);
    EXPECT(err != NULL);
    llama_engine_free_string(err);
}

static void test_not_loaded(llama_engine_t * engine) {
    fprintf(stderr, "  * calls before load\n");
    int32_t * tokens = NULL;
    size_t    n      = 0;
    char *    out    = NULL;
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_UNLOADED);
    EXPECT_STATUS(llama_engine_tokenize(engine, "hello", true, &tokens, &n), LLAMA_ENGINE_ERR_NOT_LOADED);
    EXPECT(tokens == NULL && n == 0);
    EXPECT_STATUS(llama_engine_chat_completion(engine, k_chat_request, &out), LLAMA_ENGINE_ERR_NOT_LOADED);
    EXPECT(out == NULL);
    EXPECT(!llama_engine_is_mtp_active(engine));
    EXPECT_STATUS(llama_engine_unload(engine), LLAMA_ENGINE_OK);
    EXPECT_STATUS(llama_engine_load(engine, NULL), LLAMA_ENGINE_ERR_INVALID_ARG);
}

static void test_tokens(llama_engine_t * engine) {
    fprintf(stderr, "  * tokenize / detokenize / count\n");
    int32_t * tokens = NULL;
    size_t    n      = 0;
    EXPECT_STATUS(llama_engine_tokenize(engine, "Once upon a time", false, &tokens, &n), LLAMA_ENGINE_OK);
    EXPECT(tokens != NULL && n > 0);

    char * text = NULL;
    EXPECT_STATUS(llama_engine_detokenize(engine, tokens, n, &text), LLAMA_ENGINE_OK);
    EXPECT(text != NULL && strstr(text, "upon a time") != NULL);
    llama_engine_free_string(text);
    llama_engine_free_tokens(tokens);

    char * count = NULL;
    EXPECT_STATUS(llama_engine_count_chat_tokens(engine, k_chat_request, &count), LLAMA_ENGINE_OK);
    EXPECT(count != NULL && strstr(count, "input_tokens") != NULL);
    llama_engine_free_string(count);
}

static void test_completion(llama_engine_t * engine) {
    fprintf(stderr, "  * chat completion\n");
    char * out = NULL;
    EXPECT_STATUS(llama_engine_chat_completion(engine, k_chat_request, &out), LLAMA_ENGINE_OK);
    EXPECT(out != NULL && strstr(out, "\"choices\"") != NULL);
    llama_engine_free_string(out);

    out = NULL;
    EXPECT_STATUS(llama_engine_chat_completion(engine, "{not json", &out), LLAMA_ENGINE_ERR_INVALID_REQUEST);
    llama_engine_free_string(out);
}

static void test_stream(llama_engine_t * engine) {
    fprintf(stderr, "  * stream until done\n");
    llama_engine_stream_t * stream = NULL;
    EXPECT_STATUS(llama_engine_chat_completion_stream(engine, k_stream_request, &stream), LLAMA_ENGINE_OK);
    EXPECT(stream != NULL);
    if (!stream) return;

    int  n_chunks = 0;
    bool done     = false;
    for (int i = 0; i < 1000 && !done; i++) {
        char * chunk = NULL;
        llama_engine_status st = llama_engine_stream_next(stream, &chunk, &done);
        if (st != LLAMA_ENGINE_OK) {
            EXPECT_STATUS(st, LLAMA_ENGINE_OK);
            llama_engine_free_string(chunk);
            break;
        }
        if (!done) {
            EXPECT(chunk != NULL);
            n_chunks++;
        } else {
            EXPECT(chunk == NULL);
        }
        llama_engine_free_string(chunk);
    }
    EXPECT(done);
    EXPECT(n_chunks > 0);
    llama_engine_stream_close(stream);
}

static void test_stream_cancel(llama_engine_t * engine) {
    fprintf(stderr, "  * stream cancel\n");
    llama_engine_stream_t * stream = NULL;
    EXPECT_STATUS(llama_engine_chat_completion_stream(engine, k_stream_request, &stream), LLAMA_ENGINE_OK);
    if (!stream) return;

    llama_engine_stream_cancel(stream);
    bool ended = false;
    for (int i = 0; i < 1000 && !ended; i++) {
        char * chunk = NULL;
        bool   done  = false;
        llama_engine_status st = llama_engine_stream_next(stream, &chunk, &done);
        llama_engine_free_string(chunk);
        ended = done || st == LLAMA_ENGINE_ERR_CANCELLED;
        if (st != LLAMA_ENGINE_OK && st != LLAMA_ENGINE_ERR_CANCELLED) {
            EXPECT_STATUS(st, LLAMA_ENGINE_ERR_CANCELLED);
            break;
        }
    }
    EXPECT(ended);
    llama_engine_stream_close(stream);
}

static bool caps_contain(llama_engine_t * engine, const char * needle) {
    char * json = NULL;
    llama_engine_status st = llama_engine_get_capabilities(engine, &json);
    bool found = st == LLAMA_ENGINE_OK && json != NULL && strstr(json, needle) != NULL;
    llama_engine_free_string(json);
    return found;
}

static void test_probe_chat_capabilities(const llama_engine_config * cfg) {
    fprintf(stderr, "  * probe chat capabilities\n");
    char * json = NULL;
    char * err  = NULL;
    EXPECT_STATUS(llama_engine_probe_chat_capabilities(cfg, &json, &err), LLAMA_ENGINE_OK);
    EXPECT(err == NULL);
    // stories15M has no template: the chatml fallback is reported as the GGUF one
    EXPECT(json != NULL && strstr(json, "\"schema_version\":1") != NULL);
    EXPECT(json != NULL && strstr(json, "\"source\":\"gguf\"") != NULL);
    llama_engine_free_string(json);
}

static void test_capabilities(llama_engine_t * engine) {
    fprintf(stderr, "  * runtime capabilities\n");
    EXPECT(caps_contain(engine, "\"schema_version\":1"));
    EXPECT(caps_contain(engine, "\"reasoning_effort_levels\""));
    EXPECT(caps_contain(engine, "\"engine_operations\""));
    EXPECT(caps_contain(engine, "\"chat_completion\":true"));
    EXPECT(caps_contain(engine, "\"image_input\":false"));
    EXPECT(caps_contain(engine, "\"realtime\":false"));
    EXPECT(caps_contain(engine, "\"multimodal_projector\":false"));
    EXPECT_STATUS(llama_engine_get_capabilities(engine, NULL), LLAMA_ENGINE_ERR_INVALID_ARG);
}

static void test_measure_memory(llama_engine_t * engine, const llama_engine_config * cfg) {
    fprintf(stderr, "  * measure memory while loaded\n");
    char * json = NULL;
    char * err  = NULL;
    EXPECT_STATUS(llama_engine_measure_memory(cfg, &json, &err), LLAMA_ENGINE_OK);
    EXPECT(err == NULL);
    EXPECT(json != NULL && strstr(json, "\"source\":\"native\"") != NULL);
    EXPECT(json != NULL && strstr(json, "\"n_ctx\":256") != NULL);
    EXPECT(json != NULL && strstr(json, "\"complete\":true") != NULL);
    llama_engine_free_string(json);

    // the loaded engine is left alone
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_READY);
    char * out = NULL;
    EXPECT_STATUS(llama_engine_chat_completion(engine, k_chat_request, &out), LLAMA_ENGINE_OK);
    llama_engine_free_string(out);

    llama_engine_config missing = *cfg;
    missing.model_path = "/nonexistent/model.gguf";
    json = NULL;
    EXPECT_STATUS(llama_engine_measure_memory(&missing, &json, &err), LLAMA_ENGINE_ERR_LOAD_FAILED);
    EXPECT(json == NULL && err != NULL);
    llama_engine_free_string(err);
}

static void test_pause_resume(llama_engine_t * engine) {
    fprintf(stderr, "  * pause / resume\n");
    EXPECT_STATUS(llama_engine_pause(engine), LLAMA_ENGINE_OK);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_PAUSED);
    EXPECT_STATUS(llama_engine_pause(engine), LLAMA_ENGINE_OK);

    // the getter does not resume a paused engine
    char * json = NULL;
    EXPECT_STATUS(llama_engine_get_capabilities(engine, &json), LLAMA_ENGINE_ERR_NOT_LOADED);
    EXPECT(json == NULL);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_PAUSED);

    EXPECT_STATUS(llama_engine_resume(engine), LLAMA_ENGINE_OK);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_READY);
    EXPECT(caps_contain(engine, "\"schema_version\":1"));

    // a request on a paused engine resumes it
    EXPECT_STATUS(llama_engine_pause(engine), LLAMA_ENGINE_OK);
    char * out = NULL;
    EXPECT_STATUS(llama_engine_chat_completion(engine, k_chat_request, &out), LLAMA_ENGINE_OK);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_READY);
    llama_engine_free_string(out);
}

static void test_unload(llama_engine_t * engine, const llama_engine_config * cfg) {
    fprintf(stderr, "  * unload and errors after unload\n");
    EXPECT_STATUS(llama_engine_load(engine, cfg), LLAMA_ENGINE_ERR_ALREADY_LOADED);
    EXPECT_STATUS(llama_engine_unload(engine), LLAMA_ENGINE_OK);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_UNLOADED);

    char * out = NULL;
    EXPECT_STATUS(llama_engine_chat_completion(engine, k_chat_request, &out), LLAMA_ENGINE_ERR_NOT_LOADED);
    EXPECT(out == NULL);
    EXPECT(llama_engine_last_error(engine) != NULL);
    EXPECT_STATUS(llama_engine_resume(engine), LLAMA_ENGINE_ERR_NOT_LOADED);
    EXPECT(!caps_contain(engine, "schema_version"));

    // a reload with another template must not show the old snapshot
    llama_engine_config cfg_override = *cfg;
    cfg_override.chat_template_override = "chatml";
    EXPECT_STATUS(llama_engine_load(engine, &cfg_override), LLAMA_ENGINE_OK);
    EXPECT(caps_contain(engine, "\"source\":\"override\""));
    EXPECT_STATUS(llama_engine_unload(engine), LLAMA_ENGINE_OK);
}

int main(int argc, char ** argv) {
    if (argc < 2 || argv[1][0] == '\0') {
        fprintf(stderr, "SKIP: no model given\n");
        return 77;
    }
    const char * model_path = argv[1];
    const int    gpu_layers = argc > 2 ? atoi(argv[2]) : 0;

    llama_engine_set_log_level(LLAMA_ENGINE_LOG_ERROR);

    test_probe(model_path);

    llama_engine_t * engine = llama_engine_create();
    EXPECT(engine != NULL);
    if (!engine) return 1;

    test_not_loaded(engine);
    EXPECT(!caps_contain(engine, "schema_version"));

    llama_engine_config cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.model_path         = model_path;
    cfg.context_size       = 256;
    cfg.gpu_layers         = gpu_layers;
    cfg.parallel_slots     = 1;
    cfg.cpu_threads        = 2;
    cfg.seed               = 42;
    cfg.use_mmap           = true;
    cfg.kv_cache_type      = LLAMA_ENGINE_KV_F16;
    cfg.idle_pause_seconds = -1;

    test_probe_chat_capabilities(&cfg);

    EXPECT_STATUS(llama_engine_load(engine, &cfg), LLAMA_ENGINE_OK);
    if (llama_engine_get_state(engine) != LLAMA_ENGINE_STATE_READY) {
        const char * err = llama_engine_last_error(engine);
        fprintf(stderr, "load failed: %s\n", err ? err : "(no error)");
        llama_engine_destroy(engine);
        return 1;
    }

    test_capabilities(engine);
    test_tokens(engine);
    test_completion(engine);
    test_stream(engine);
    test_stream_cancel(engine);
    test_measure_memory(engine, &cfg);
    test_pause_resume(engine);
    test_unload(engine, &cfg);

    // destroy must also tear down a loaded engine
    EXPECT_STATUS(llama_engine_load(engine, &cfg), LLAMA_ENGINE_OK);
    llama_engine_destroy(engine);

    printf("\n===== %d / %d passed =====\n", g_total - g_failures, g_total);
    return g_failures == 0 ? 0 : 1;
}
