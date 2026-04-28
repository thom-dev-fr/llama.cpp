#include "llama_engine.h"
#include "engine_core.hpp"

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

extern "C" llama_engine_status llama_engine_get_capabilities(
    llama_engine_t * engine, llama_engine_capabilities * out)
{
    if (!engine || !out) return LLAMA_ENGINE_ERR_INVALID_ARG;
    *out = llama_engine_capabilities{};
    return engine->core.capabilities(*out);
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
    common_log_set_verbosity_thold(verbosity);
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
