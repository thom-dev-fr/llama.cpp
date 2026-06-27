#include "llama_engine.h"
#include "engine_core.hpp"
#include "caps_probe.hpp"

#include "log.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

using llama_engine::engine_core;
using llama_engine::stream_handle;

struct llama_engine_t {
    engine_core core;
    // Buffer returned by llama_engine_last_error(), kept alive until the next call.
    std::string last_error_buf;
};

struct llama_engine_stream_t {
    stream_handle * handle;
    engine_core   * owner;
};

static char * dup_string(const std::string & s) {
    char * out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

extern "C" llama_engine_t * llama_engine_create(void) {
    return new (std::nothrow) llama_engine_t();
}

extern "C" void llama_engine_destroy(llama_engine_t * engine) {
    delete engine;
}

extern "C" llama_engine_status llama_engine_load(llama_engine_t * engine,
                                                 const llama_engine_config * config)
{
    if (!engine || !config) return LLAMA_ENGINE_ERR_INVALID_ARG;
    return engine->core.load(*config);
}

extern "C" llama_engine_status llama_engine_unload(llama_engine_t * engine) {
    if (!engine) return LLAMA_ENGINE_ERR_INVALID_ARG;
    return engine->core.unload();
}

extern "C" llama_engine_status llama_engine_pause(llama_engine_t * engine) {
    if (!engine) return LLAMA_ENGINE_ERR_INVALID_ARG;
    return engine->core.pause();
}

extern "C" llama_engine_status llama_engine_resume(llama_engine_t * engine) {
    if (!engine) return LLAMA_ENGINE_ERR_INVALID_ARG;
    return engine->core.resume();
}

extern "C" llama_engine_state llama_engine_get_state(llama_engine_t * engine) {
    if (!engine) return LLAMA_ENGINE_STATE_UNLOADED;
    return engine->core.state();
}

extern "C" llama_engine_status llama_engine_probe_model_info(
    const char              * model_path,
    const char              * mmproj_path,
    llama_engine_model_info * out,
    char                   ** out_error_msg)
{
    if (out_error_msg) *out_error_msg = nullptr;
    if (!out) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out = llama_engine_model_info{};
    if (!model_path) {
        if (out_error_msg) *out_error_msg = dup_string("model_path is required");
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }
    std::string err;
    auto st = llama_engine::probe_model_info(model_path, mmproj_path, *out, err);
    if (st != LLAMA_ENGINE_OK && out_error_msg && !err.empty()) {
        *out_error_msg = dup_string(err);
    }
    return st;
}

static void free_gguf_metadata(llama_engine_gguf_metadata & meta) {
    std::free(meta.size_label);
    meta.size_label = nullptr;

    if (meta.languages) {
        for (size_t i = 0; i < meta.languages_count; ++i) {
            std::free(meta.languages[i]);
        }
        std::free(meta.languages);
    }
    meta.languages = nullptr;
    meta.languages_count = 0;

    meta = llama_engine_gguf_metadata{};
}

static void free_projector_info(llama_engine_projector_info & projector) {
    free_gguf_metadata(projector.metadata);
    std::free(projector.projector_type);
    projector.projector_type = nullptr;
    projector = llama_engine_projector_info{};
}

extern "C" void llama_engine_free_model_info(llama_engine_model_info * info) {
    if (!info) return;
    free_gguf_metadata(info->metadata);
    free_projector_info(info->projector);
    std::free(info->architecture); info->architecture = nullptr;
    std::free(info->name);         info->name         = nullptr;
    std::free(info->quantization); info->quantization = nullptr;
    info->capabilities  = llama_engine_capabilities{};
    info->has_projector = false;
}

extern "C" bool llama_engine_is_mtp_active(llama_engine_t * engine) {
    if (!engine) return false;
    return engine->core.is_mtp_active();
}

extern "C" const char * llama_engine_last_error(llama_engine_t * engine) {
    if (!engine) return nullptr;
    const char * msg = engine->core.last_error();
    if (!msg) return nullptr;
    engine->last_error_buf = msg;
    return engine->last_error_buf.c_str();
}

extern "C" void llama_engine_set_log_level(llama_engine_log_level level) {
    int verbosity = 0;
    switch (level) {
        case LLAMA_ENGINE_LOG_OFF:     verbosity = -1; break;
        case LLAMA_ENGINE_LOG_ERROR:   verbosity = 0;  break;
        case LLAMA_ENGINE_LOG_WARNING: verbosity = 1;  break;
        case LLAMA_ENGINE_LOG_INFO:    verbosity = 2;  break;
        case LLAMA_ENGINE_LOG_DEBUG:   verbosity = 4;  break;
    }
    engine_core::set_log_verbosity(verbosity);
}

extern "C" llama_engine_status llama_engine_tokenize(
    llama_engine_t * engine, const char * text, bool add_special,
    int32_t ** out_tokens, size_t * out_n)
{
    if (!engine || !text || !out_tokens || !out_n) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_tokens = nullptr;
    *out_n = 0;

    std::vector<int32_t> toks;
    auto st = engine->core.tokenize(text, add_special, toks);
    if (st != LLAMA_ENGINE_OK) return st;

    int32_t * buf = static_cast<int32_t *>(std::malloc(sizeof(int32_t) * toks.size()));
    if (!buf && !toks.empty()) return LLAMA_ENGINE_ERR_INTERNAL;
    if (!toks.empty()) std::memcpy(buf, toks.data(), sizeof(int32_t) * toks.size());
    *out_tokens = buf;
    *out_n = toks.size();
    return LLAMA_ENGINE_OK;
}

extern "C" void llama_engine_free_tokens(int32_t * tokens) {
    std::free(tokens);
}

extern "C" llama_engine_status llama_engine_detokenize(
    llama_engine_t * engine, const int32_t * tokens, size_t n_tokens, char ** out_text)
{
    if (!engine || (!tokens && n_tokens > 0) || !out_text) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_text = nullptr;

    std::vector<int32_t> toks(tokens, tokens + n_tokens);
    std::string out;
    auto st = engine->core.detokenize(toks, out);
    if (st != LLAMA_ENGINE_OK) return st;

    *out_text = dup_string(out);
    return *out_text ? LLAMA_ENGINE_OK : LLAMA_ENGINE_ERR_INTERNAL;
}

extern "C" void llama_engine_free_string(char * str) {
    std::free(str);
}

extern "C" llama_engine_status llama_engine_count_chat_tokens(
    llama_engine_t * engine, const char * request_json, char ** out_response)
{
    if (!engine || !request_json || !out_response) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_response = nullptr;

    std::string out;
    auto st = engine->core.count_chat_tokens(request_json, out);
    if (st != LLAMA_ENGINE_OK && st != LLAMA_ENGINE_ERR_INFERENCE) return st;

    *out_response = dup_string(out);
    if (!*out_response) return LLAMA_ENGINE_ERR_INTERNAL;
    return st;
}

extern "C" llama_engine_status llama_engine_chat_completion(
    llama_engine_t * engine, const char * request_json, char ** out_response)
{
    if (!engine || !request_json || !out_response) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_response = nullptr;

    std::string out;
    auto st = engine->core.chat_completion(request_json, out);
    if (st != LLAMA_ENGINE_OK && st != LLAMA_ENGINE_ERR_INFERENCE) return st;

    *out_response = dup_string(out);
    if (!*out_response) return LLAMA_ENGINE_ERR_INTERNAL;
    return st;
}

extern "C" llama_engine_status llama_engine_chat_completion_stream(
    llama_engine_t * engine, const char * request_json, llama_engine_stream_t ** out_stream)
{
    if (!engine || !request_json || !out_stream) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_stream = nullptr;

    stream_handle * handle = nullptr;
    auto st = engine->core.chat_completion_stream(request_json, &handle);
    if (st != LLAMA_ENGINE_OK || !handle) {
        if (handle) engine->core.stream_close(handle);
        return st;
    }

    auto * wrapper = new (std::nothrow) llama_engine_stream_t();
    if (!wrapper) {
        engine->core.stream_close(handle);
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    wrapper->handle = handle;
    wrapper->owner  = &engine->core;
    *out_stream = wrapper;
    return LLAMA_ENGINE_OK;
}

extern "C" llama_engine_status llama_engine_stream_next(
    llama_engine_stream_t * stream, char ** out_chunk_json, bool * out_done)
{
    if (!stream || !out_chunk_json || !out_done) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out_chunk_json = nullptr;
    *out_done = false;

    std::string chunk;
    bool done = false;
    auto st = stream->owner->stream_next(stream->handle, chunk, done);
    *out_done = done;
    if (!chunk.empty()) {
        *out_chunk_json = dup_string(chunk);
        if (!*out_chunk_json) return LLAMA_ENGINE_ERR_INTERNAL;
    }
    return st;
}

extern "C" void llama_engine_stream_cancel(llama_engine_stream_t * stream) {
    if (!stream) return;
    stream->owner->stream_cancel(stream->handle);
}

extern "C" void llama_engine_stream_close(llama_engine_stream_t * stream) {
    if (!stream) return;
    stream->owner->stream_close(stream->handle);
    delete stream;
}
