#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

// C interface of the llama.cpp inference engine for the Apple bindings.
//
// An integration detail of bindings/apple: applications use the Swift modules.
// Opaque handles over include/llama-engine.h; requests and results are the
// engine's JSON contracts (docs/design/embedded-inference-engine-api.md),
// passed as UTF-8 strings. No ABI stability is promised.
//
// Errors: no C++ exception crosses this interface. A failing call returns NULL
// (or an error event) and, when asked, an owned error event.
//
// Ownership: every returned handle, event and string is owned by the caller
// and released with the matching *_free / *_destroy function. Inputs (strings,
// attachment bytes) are copied before the call returns.
//
// Threads: functions may be called from any thread, with these rules:
// - one reader at a time per request or subscription (next);
// - llama_bridge_request_cancel may run concurrently with that reader;
// - destroying a handle must not race any other call on the same handle;
// - a request or subscription may outlive its engine.
// next, unload, update_catalog, stop and engine destruction block: call them
// from a thread that may block.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LLAMA_BRIDGE_API __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llama_bridge_engine       llama_bridge_engine;
typedef struct llama_bridge_request      llama_bridge_request;
typedef struct llama_bridge_subscription llama_bridge_subscription;
typedef struct llama_bridge_event        llama_bridge_event;

typedef enum {
    LLAMA_BRIDGE_EVENT_PAYLOAD   = 0, // data: one native payload (null marks generation start)
    LLAMA_BRIDGE_EVENT_SUCCESS   = 1, // terminal; data: the complete result when available
    LLAMA_BRIDGE_EVENT_ERROR     = 2, // terminal; category, message, data: native details
    LLAMA_BRIDGE_EVENT_CANCELLED = 3, // terminal; category: cancelled, stopped, unloaded, ...
    LLAMA_BRIDGE_EVENT_TIMEOUT   = 4, // not terminal: nothing arrived in time
} llama_bridge_event_type;

typedef struct {
    const char *    name;  // referenced as "attachment:<name>" in the request
    const uint8_t * bytes;
    size_t          size;
} llama_bridge_attachment;

// Events
LLAMA_BRIDGE_API llama_bridge_event_type llama_bridge_event_get_type(const llama_bridge_event * event);
LLAMA_BRIDGE_API bool         llama_bridge_event_is_terminal(const llama_bridge_event * event);
// Valid until the event is freed; never NULL ("" when absent, "null" for no data).
LLAMA_BRIDGE_API const char * llama_bridge_event_get_data(const llama_bridge_event * event);
LLAMA_BRIDGE_API const char * llama_bridge_event_get_category(const llama_bridge_event * event);
LLAMA_BRIDGE_API const char * llama_bridge_event_get_message(const llama_bridge_event * event);
LLAMA_BRIDGE_API void         llama_bridge_event_free(llama_bridge_event * event);

LLAMA_BRIDGE_API void llama_bridge_string_free(char * string);

// Engine
//
// Catalog configuration (JSON):
// {"max_loaded": 1, "autoload": true, "wait_timeout_ms": 300000, "max_waiting": 4,
//  "max_subscriber_events": 256,
//  "models": [{"id": "...", "aliases": [...], "settings": {
//      "model_path": "...", "mmproj_path": "...", "context_size": 4096, "parallel": 1,
//      "threads": 4, "gpu_layers": 99, "batch_size": 512, "micro_batch_size": 512,
//      "chat_template": "...", "max_tasks": 64, "max_events": 256,
//      "options": {"flash-attn": "on", ...}}}]}
// Absent fields keep the engine defaults; null typed settings keep llama.cpp's.
LLAMA_BRIDGE_API llama_bridge_engine * llama_bridge_engine_create(const char * catalog_json, llama_bridge_event ** error);
// Stops the engine (if needed) and frees it. Blocks until its threads end.
LLAMA_BRIDGE_API void llama_bridge_engine_destroy(llama_bridge_engine * engine);
// Closes admissions, cancels the work, wakes the readers and joins. Idempotent.
LLAMA_BRIDGE_API void llama_bridge_engine_stop(llama_bridge_engine * engine);

// Operation names as in llama_engine::operation: "chat", "completion",
// "tokenize", "apply_template", "chat_tokens", ... Preparation (templates,
// tokens, media) runs on the calling thread.
LLAMA_BRIDGE_API llama_bridge_request * llama_bridge_engine_submit(llama_bridge_engine * engine, const char * operation,
                                                  const char * request_json,
                                                  const llama_bridge_attachment * attachments, size_t n_attachments,
                                                  llama_bridge_event ** error);
// Catalog snapshot (JSON array), or NULL on error.
LLAMA_BRIDGE_API char * llama_bridge_engine_catalog(const llama_bridge_engine * engine, llama_bridge_event ** error);
// Loads a model; the request succeeds once it is resident.
LLAMA_BRIDGE_API llama_bridge_request * llama_bridge_engine_load(llama_bridge_engine * engine, const char * model,
                                                llama_bridge_event ** error);
// Explicit unload; blocks until the model's work stopped and its resources are freed.
LLAMA_BRIDGE_API llama_bridge_event * llama_bridge_engine_unload(llama_bridge_engine * engine, const char * model);
// Replaces the catalog models (JSON array of models, as in the configuration).
LLAMA_BRIDGE_API llama_bridge_event * llama_bridge_engine_update_catalog(llama_bridge_engine * engine, const char * models_json);
LLAMA_BRIDGE_API llama_bridge_subscription * llama_bridge_engine_subscribe(llama_bridge_engine * engine, llama_bridge_event ** error);

// Requests. timeout_ms < 0 waits without limit. NULL only when out of memory.
LLAMA_BRIDGE_API llama_bridge_event * llama_bridge_request_next(llama_bridge_request * request, int64_t timeout_ms);
LLAMA_BRIDGE_API void llama_bridge_request_cancel(llama_bridge_request * request);
// Cancels unfinished work, then frees the handle.
LLAMA_BRIDGE_API void llama_bridge_request_destroy(llama_bridge_request * request);

// Model state events: a "snapshot" first, then "status", "progress", "resync", ...
LLAMA_BRIDGE_API llama_bridge_event * llama_bridge_subscription_next(llama_bridge_subscription * subscription, int64_t timeout_ms);
LLAMA_BRIDGE_API void llama_bridge_subscription_destroy(llama_bridge_subscription * subscription);

#ifdef __cplusplus
}
#endif

#endif // LLAMA_BRIDGE_H
