#ifndef LLAMA_ENGINE_H
#define LLAMA_ENGINE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llama_engine_t llama_engine_t;
typedef struct llama_engine_stream_t llama_engine_stream_t;

typedef enum {
    LLAMA_ENGINE_OK                = 0,
    LLAMA_ENGINE_ERR_NOT_LOADED    = 1,
    LLAMA_ENGINE_ERR_ALREADY_LOADED = 2,
    LLAMA_ENGINE_ERR_LOAD_FAILED   = 3,
    LLAMA_ENGINE_ERR_INVALID_ARG   = 4,
    LLAMA_ENGINE_ERR_INVALID_REQUEST = 5,
    LLAMA_ENGINE_ERR_INFERENCE     = 6,
    LLAMA_ENGINE_ERR_CANCELLED     = 7,
    LLAMA_ENGINE_ERR_TIMEOUT       = 8,
    LLAMA_ENGINE_ERR_INTERNAL      = 99,
} llama_engine_status;

typedef enum {
    LLAMA_ENGINE_STATE_UNLOADED  = 0,
    LLAMA_ENGINE_STATE_LOADING   = 1,
    LLAMA_ENGINE_STATE_READY     = 2,
    LLAMA_ENGINE_STATE_SLEEPING  = 3,
    LLAMA_ENGINE_STATE_UNLOADING = 4,
} llama_engine_state;

typedef enum {
    LLAMA_ENGINE_KV_F32    = 0,
    LLAMA_ENGINE_KV_F16    = 1,
    LLAMA_ENGINE_KV_BF16   = 2,
    LLAMA_ENGINE_KV_Q8_0   = 3,
    LLAMA_ENGINE_KV_Q4_0   = 4,
    LLAMA_ENGINE_KV_Q5_0   = 5,
    LLAMA_ENGINE_KV_IQ4_NL = 6,
} llama_engine_kv_type;

typedef enum {
    LLAMA_ENGINE_LOG_OFF     = 0,
    LLAMA_ENGINE_LOG_ERROR   = 1,
    LLAMA_ENGINE_LOG_WARNING = 2,
    LLAMA_ENGINE_LOG_INFO    = 3,
    LLAMA_ENGINE_LOG_DEBUG   = 4,
} llama_engine_log_level;

// Configuration passed to llama_engine_load.
// Strings must remain valid for the duration of the call; they are copied internally.
typedef struct {
    const char * model_path;                 // required
    int32_t      context_size;               // n_ctx. 0 => default (4096)
    int32_t      gpu_layers;                 // -1 => all
    int32_t      parallel_slots;             // n_parallel. 0 => 1
    int32_t      cpu_threads;                // 0 or <0 => auto (hw_concurrency)
    uint32_t     seed;                       // 0xFFFFFFFF => LLAMA_DEFAULT_SEED
    const char * mtmd_projector_path;        // optional, NULL to disable. enables image/audio inputs when the model ships with a compatible mmproj.
    const char * chat_template_override;     // optional, NULL to use GGUF-embedded template
    bool         use_mmap;
    bool         use_mlock;
    bool         flash_attention;
    llama_engine_kv_type kv_cache_type;
    int32_t      idle_sleep_seconds;         // -1 => disabled
    const char * extra_json;                 // optional, NULL or JSON object merged into common_params
} llama_engine_config;

// Creation / destruction. llama_backend_init() is called once on first create.
llama_engine_t * llama_engine_create(void);
void             llama_engine_destroy(llama_engine_t * engine);

// Lifecycle.
llama_engine_status llama_engine_load(llama_engine_t * engine, const llama_engine_config * config);
llama_engine_status llama_engine_unload(llama_engine_t * engine);

// Transition the engine to the SLEEPING state, releasing the model context
// while retaining the configuration so a later llama_engine_wake() can
// restore it. Thread-safe and may be called concurrently from another thread:
//   - from READY:    tears down the context synchronously.
//   - from LOADING:  preempts the in-flight load or wake via the llama.cpp
//                    model load progress callback. The call blocks until the
//                    loading thread observes the cancellation; the concurrent
//                    llama_engine_load() / llama_engine_wake() call returns
//                    LLAMA_ENGINE_ERR_CANCELLED. This is the iOS
//                    background-transition case: sleep() unblocks a long
//                    load without leaving the engine in an inconsistent state.
//   - from SLEEPING: no-op, returns LLAMA_ENGINE_OK.
llama_engine_status llama_engine_sleep(llama_engine_t * engine);

llama_engine_status llama_engine_wake(llama_engine_t * engine);
llama_engine_state  llama_engine_get_state(llama_engine_t * engine);

// Capabilities of the currently loaded model. Only meaningful when the engine
// is in READY or SLEEPING state; returns LLAMA_ENGINE_ERR_NOT_LOADED otherwise.
typedef struct {
    bool has_mtmd;              // true if an mmproj was loaded alongside the model
    bool supports_vision;       // true if image inputs are accepted
    bool supports_audio;        // true if audio inputs are accepted (wav/mp3)
    bool supports_tool_calls;   // true if the loaded chat template advertises tool-call rendering
    bool supports_reasoning;    // true if the loaded chat template preserves reasoning_content across turns
} llama_engine_capabilities;

llama_engine_status llama_engine_get_capabilities(
    llama_engine_t            * engine,
    llama_engine_capabilities * out);

// Retrieve the most recent error message attached to `engine`.
// Returned pointer is valid until the next call on `engine`.
// Returns NULL if there is no pending error.
const char * llama_engine_last_error(llama_engine_t * engine);

// Control.
void llama_engine_set_log_level(llama_engine_log_level level);

// Tokenization.
// On success, *out_tokens points to a heap-allocated int32_t array of length *out_n.
// Caller must free with llama_engine_free_tokens().
llama_engine_status llama_engine_tokenize(
    llama_engine_t * engine,
    const char     * text,
    bool             add_special,
    int32_t       ** out_tokens,
    size_t         * out_n);

void llama_engine_free_tokens(int32_t * tokens);

// On success, *out_text points to a heap-allocated NUL-terminated string.
// Caller must free with llama_engine_free_string().
llama_engine_status llama_engine_detokenize(
    llama_engine_t * engine,
    const int32_t  * tokens,
    size_t           n_tokens,
    char          ** out_text);

void llama_engine_free_string(char * str);

// Chat completion (non-stream).
// `request_json` is OAI-compatible JSON; it is parsed internally.
// On success, *out_response is a heap-allocated NUL-terminated JSON string.
// Caller must free with llama_engine_free_string().
llama_engine_status llama_engine_chat_completion(
    llama_engine_t * engine,
    const char     * request_json,
    char          ** out_response);

// Chat completion (stream).
// Opens a stream handle; pump chunks with llama_engine_stream_next().
// The stream must always be closed with llama_engine_stream_close(), even after cancellation or error.
llama_engine_status llama_engine_chat_completion_stream(
    llama_engine_t          * engine,
    const char              * request_json,
    llama_engine_stream_t  ** out_stream);

// Block until the next chunk is available or the stream terminates.
// On success returns LLAMA_ENGINE_OK and:
//   - If *out_done == false, *out_chunk_json is a heap-allocated JSON string (free with llama_engine_free_string).
//   - If *out_done == true, the stream has ended; *out_chunk_json is NULL. Close the stream.
// On error, returns a non-OK status and leaves *out_chunk_json == NULL.
llama_engine_status llama_engine_stream_next(
    llama_engine_stream_t * stream,
    char                 ** out_chunk_json,
    bool                  * out_done);

// Request cancellation. Safe to call from any thread.
// The next stream_next() will observe the cancellation and return LLAMA_ENGINE_ERR_CANCELLED or set *out_done.
void llama_engine_stream_cancel(llama_engine_stream_t * stream);

void llama_engine_stream_close(llama_engine_stream_t * stream);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // LLAMA_ENGINE_H
