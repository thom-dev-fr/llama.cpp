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
    LLAMA_ENGINE_STATE_PAUSED    = 3,
    LLAMA_ENGINE_STATE_UNLOADING = 4,
    LLAMA_ENGINE_STATE_PAUSING   = 5,
    LLAMA_ENGINE_STATE_RESUMING  = 6,
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
    int32_t      idle_pause_seconds;         // -1 => disabled

    // Multi-Token Prediction (MTP) speculative decoding.
    // When `enable_mtp` is true, the engine enables
    // COMMON_SPECULATIVE_TYPE_DRAFT_MTP. Two modes are supported:
    //   - self-MTP: leave `mtp_draft_model_path` NULL/empty and load a
    //     model whose GGUF carries an MTP head (e.g. recent Qwen3 MTP
    //     variants). The engine spins up a second context over the same
    //     target model with ctx_type = LLAMA_CONTEXT_TYPE_MTP.
    //   - external draft head: set `mtp_draft_model_path` to a sibling
    //     `mtp-*.gguf` file (the same file the upstream `-hf` auto-discovery
    //     would pick). It is loaded as the draft model, again with
    //     ctx_type = LLAMA_CONTEXT_TYPE_MTP.
    // Drafting knobs (n_max / n_min / p_min) can be overridden through
    // `extra_json` under the "mtp" object, e.g.
    //   {"mtp": {"n_max": 4, "n_min": 0, "p_min": 0.0}}
    // The defaults match upstream `common_params_speculative_draft`.
    // Note: MTP cannot be combined with other speculative types in this
    // build; the engine sets exactly DRAFT_MTP when `enable_mtp` is true.
    bool         enable_mtp;
    const char * mtp_draft_model_path;       // optional, NULL for self-MTP

    const char * extra_json;                 // optional, NULL or JSON object merged into common_params
} llama_engine_config;

// Creation / destruction. Backend initialization is lazy and happens once on
// first real model load/resume, not during engine creation.
llama_engine_t * llama_engine_create(void);
void             llama_engine_destroy(llama_engine_t * engine);

// Lifecycle.
llama_engine_status llama_engine_load(llama_engine_t * engine, const llama_engine_config * config);
llama_engine_status llama_engine_unload(llama_engine_t * engine);

// Transition the engine to the PAUSED state, releasing the model context
// while retaining the configuration so a later llama_engine_resume() can
// restore it. Thread-safe and may be called concurrently from another thread:
//   - from READY:     transitions through PAUSING and tears down synchronously.
//   - from LOADING:   preempts the in-flight load via the llama.cpp model
//                     load progress callback. The call blocks until the
//                     loading thread observes the cancellation; the concurrent
//                     llama_engine_load() call returns
//                     LLAMA_ENGINE_ERR_CANCELLED. This lets callers preempt a
//                     long load without leaving the engine in an inconsistent
//                     state.
//   - from RESUMING:  same preemption mechanism as LOADING; the concurrent
//                     llama_engine_resume() call returns
//                     LLAMA_ENGINE_ERR_CANCELLED.
//   - from PAUSING:   waits for the in-flight pause to finish, returns OK.
//   - from PAUSED:    no-op, returns LLAMA_ENGINE_OK.
llama_engine_status llama_engine_pause(llama_engine_t * engine);

// Transition from PAUSED back to READY by reloading the model with the
// previously cached configuration. Goes through RESUMING during the reload.
llama_engine_status llama_engine_resume(llama_engine_t * engine);
llama_engine_state  llama_engine_get_state(llama_engine_t * engine);

// Intrinsic capabilities of a model file (and optionally its mmproj projector).
// Populated by llama_engine_probe_model_info() *without* loading the weights
// into memory: only the GGUF metadata block is parsed.
typedef struct {
    bool has_mtmd;              // true iff a non-NULL mmproj_path was passed to the probe
                                // and that file could be opened as a valid GGUF.
    bool supports_vision;       // true if the mmproj advertises a vision encoder
                                // (clip.has_vision_encoder == true).
    bool supports_audio;        // true if the mmproj advertises an audio encoder
                                // (clip.has_audio_encoder == true).
    bool supports_tool_calls;   // true if the GGUF-embedded chat template advertises
                                // tool-call rendering (jinja caps).
    bool supports_reasoning;    // true if the chat template can emit reasoning (thinking) output as reasoning_content.
    bool has_supports_reasoning_toggle; // true if supports_reasoning_toggle is known.
    bool supports_reasoning_toggle; // meaningful only when has_supports_reasoning_toggle is true.
    bool supports_preserve_reasoning; // true if the chat template re-injects a prior assistant
                                      // `reasoning_content` field into the rendered prompt
                                      // on the next turn (rare: Qwen3 recent, GLM-4.5,
                                      // gpt-oss, DeepSeek-V3.1).
    bool supports_mtp;          // true if the model has Multi-Token Prediction heads
                                // baked in (i.e. <arch>.nextn_predict_layers > 0).
                                // This is a *capability* — whether MTP is actually wired
                                // up at runtime is reported by llama_engine_is_mtp_active().
} llama_engine_capabilities;

// Generic GGUF metadata read without loading tensor data. Optional scalar
// fields use a parallel has_* flag so callers can distinguish an absent key
// from a legitimate zero value. Strings/arrays are heap-allocated and released
// by llama_engine_free_model_info().
typedef struct {
    uint32_t version;       // GGUF container version.
    uint64_t tensor_count;  // Number of tensor descriptors in the file.

    bool     has_block_count;
    uint32_t block_count;   // `<arch>.block_count` / `<arch>.layer_count`.

    bool     has_embedding_length;
    uint32_t embedding_length; // `<arch>.embedding_length` / `<arch>.embed_length`.

    bool     has_context_length;
    uint32_t context_length;   // `<arch>.context_length`.

    bool     has_attention_head_count;
    uint32_t attention_head_count;    // `<arch>.attention.head_count` (max if stored per-layer).

    bool     has_attention_head_count_kv;
    uint32_t attention_head_count_kv; // `<arch>.attention.head_count_kv` (max if stored per-layer).

    bool     has_attention_key_length;
    uint32_t attention_key_length;    // `<arch>.attention.key_length`.

    bool     has_attention_value_length;
    uint32_t attention_value_length;  // `<arch>.attention.value_length`.

    bool     has_attention_sliding_window;
    uint32_t attention_sliding_window; // `<arch>.attention.sliding_window`.

    bool     has_attention_key_length_swa;
    uint32_t attention_key_length_swa; // `<arch>.attention.key_length_swa`.

    bool     has_attention_value_length_swa;
    uint32_t attention_value_length_swa; // `<arch>.attention.value_length_swa`.

    bool     has_nextn_predict_layers;
    uint32_t nextn_predict_layers; // `<arch>.nextn_predict_layers`.

    bool     has_attention_shared_kv_layers;
    uint32_t attention_shared_kv_layers; // `<arch>.attention.shared_kv_layers`.

    bool     has_file_type;
    uint32_t file_type;     // Raw `general.file_type` enum value.

    char *   size_label;    // `general.size_label`, NULL if absent.

    bool     has_languages; // true iff `general.languages` was present.
    char **  languages;     // `general.languages`, NULL when absent or empty.
    size_t   languages_count;

    uint64_t file_size;     // Filesystem size in bytes; 0 if stat() failed.
} llama_engine_gguf_metadata;

// Metadata specific to an optional multimodal projector GGUF.
typedef struct {
    llama_engine_gguf_metadata metadata;

    bool has_vision_encoder; // `clip.has_vision_encoder`.
    bool has_audio_encoder;  // `clip.has_audio_encoder`.

    char * projector_type;   // `*.projector_type`, NULL if absent.

    bool     has_vision_image_size;
    uint32_t vision_image_size; // `*.image_size`, if present.

    bool     has_vision_patch_size;
    uint32_t vision_patch_size; // `*.patch_size`, if present.
} llama_engine_projector_info;

// Display-oriented metadata read from the same GGUF metadata pass as the
// capabilities. All string/optional fields are best-effort: a missing source
// key in the GGUF results in NULL / has_X == false rather than an error.
typedef struct {
    llama_engine_capabilities capabilities;

    // Generic metadata for the main model GGUF.
    llama_engine_gguf_metadata metadata;

    // `general.architecture` (e.g. "llama", "qwen3", "deepseek2"). Empty
    // string if the key is absent (pathological GGUF).
    // Heap-allocated, NUL-terminated. Never NULL after a successful probe;
    // freed by llama_engine_free_model_info().
    char * architecture;

    // `general.name`. NULL if absent.
    char * name;

    // Decoded `general.file_type` enum, formatted like upstream's
    // `llama_model_ftype_name()` (e.g. "Q4_K - Medium", "F16"). NULL if absent.
    char * quantization;

    // Optional projector info, present iff a non-NULL mmproj_path was supplied
    // and the file could be opened as a valid GGUF.
    bool has_projector;
    llama_engine_projector_info projector;
} llama_engine_model_info;

// Probe a model file (and optionally its mmproj projector) for its intrinsic
// capabilities and display metadata, *without* loading the weights into
// memory. Only the GGUF metadata blocks at the start of each file are read.
//
// The probe is independent of any llama_engine_t handle: it does not require
// llama_engine_create() and does not initialise the ggml backend.
//
// On success returns LLAMA_ENGINE_OK, fills `*out`, and `*out_error_msg`
// (if non-NULL) is set to NULL. Caller must release `*out` with
// llama_engine_free_model_info().
//
// On failure returns a non-OK status, leaves `*out` zero-initialised, and
// (if `out_error_msg` is non-NULL) sets `*out_error_msg` to a heap-allocated
// NUL-terminated message that the caller frees with llama_engine_free_string().
// Errors covered: model_path NULL/missing/unreadable, model file is not a
// valid GGUF, mmproj_path was provided but unreadable / not a GGUF.
//
// Soft failures — chat template absent or unparseable, missing optional
// metadata keys, mmproj missing the clip.has_*_encoder keys — do NOT throw:
// the corresponding bool / pointer fields just stay false / NULL.
llama_engine_status llama_engine_probe_model_info(
    const char              * model_path,
    const char              * mmproj_path,    // optional, NULL to skip
    llama_engine_model_info * out,
    char                   ** out_error_msg); // optional; caller frees with llama_engine_free_string()

// Releases all heap-allocated strings inside `info` and zeroes them.
// Safe to call on a zero-initialised struct.
void llama_engine_free_model_info(llama_engine_model_info * info);

// Returns true when Multi-Token Prediction speculative decoding is currently
// wired up against the loaded model (either self-MTP on the target, or an
// external `mtp-*.gguf` draft head). Reflects the actual state after load:
// a misconfigured `enable_mtp` with an incompatible model surfaces as false.
// Returns false when the engine is not loaded, or when `engine` is NULL.
bool llama_engine_is_mtp_active(llama_engine_t * engine);

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

// Token counting.
// `request_json` is passed to /v1/chat/completions/input_tokens and the raw
// JSON response is returned.
llama_engine_status llama_engine_count_chat_tokens(
    llama_engine_t * engine,
    const char     * request_json,
    char          ** out_response);

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
