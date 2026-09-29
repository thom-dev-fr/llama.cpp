#pragma once

#include <nlohmann/json.hpp>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Experimental C++ interface; no stable ABI is promised during extraction.
namespace llama_engine {
using json = nlohmann::ordered_json; // keeps the native field order

struct attachment {
    std::string name;
    std::vector<uint8_t> bytes;
};

enum class operation {
    completion, completions, chat, responses, messages, infill, transcription,
    embeddings, embeddings_openai, rerank, tokenize, detokenize, apply_template,
    chat_tokens, response_tokens, message_tokens, control, slots, slot_save,
    slot_restore, slot_erase, lora_list, lora_apply, properties, models, metrics, properties_update,
};

struct config {
    std::string model_path;
    int context_size = 512;
    int parallel = 1;
    int threads = 2;
    int gpu_layers = 0;
    int batch_size = 128;
    int micro_batch_size = 128;
    std::string chat_template;
    std::string mmproj_path;
    bool embeddings = false;
    int pooling_type = -1; // llama_pooling_type: -1 = model default
    std::string slot_save_path; // empty disables persistent slot actions
    std::vector<std::string> lora_paths;
    // Free the model after this many idle seconds and reload it on the next
    // request (-1 disables). A failed reload is reported as wake_failed.
    int sleep_idle_seconds = -1;
    size_t max_tasks = 64;          // includes queued, active and cancelling tasks
    size_t max_events = 256;        // per request, before JSON conversion
    size_t max_request_bytes = 16 * 1024 * 1024;
    json generation_defaults = json::object();
};

enum class event_type { payload, success, error, cancelled, timeout };
struct event {
    event_type type = event_type::success;
    json data = nullptr; // null payload marks generation start (native streaming contract)
    // Errors have a stable category and optional native error details in data.
    std::string category;
    std::string message;
    bool terminal() const {
        return type == event_type::success || type == event_type::error || type == event_type::cancelled;
    }
};

// One catalog entry: selected by id or alias in the "model" field of requests.
struct model_entry {
    std::string id;
    std::vector<std::string> aliases;
    std::vector<std::string> tags;  // informational
    config settings;                // loading configuration and per-model limits
};

// Several models in one process. Loading, resident, sleeping and unloading
// models count against max_loaded; only idle models are evicted (least
// recently used first). Requests wait for a slot in first-come order.
struct catalog_config {
    std::vector<model_entry> models;
    int max_loaded = 4;             // <= 0: no limit
    bool autoload = true;           // load on demand; otherwise model_not_loaded
    std::chrono::milliseconds wait_timeout = std::chrono::minutes(5);
    size_t max_waiting = 64;        // requests (and explicit loads) waiting for a model
    size_t max_subscriber_events = 256;
};

namespace detail { struct request_state; struct engine_impl; struct subscriber_state; }

// A handle owns its buffers, independent of engine lifetime. Destroying it cancels
// unfinished work. next()/result() share one serialized reader; cancel() may run
// concurrently. Destruction must not race a method on that same C++ object.
class request {
public:
    explicit request(std::shared_ptr<detail::request_state> state);
    ~request();
    request(const request &) = delete;
    request & operator=(const request &) = delete;
    event next();
    event next_for(std::chrono::milliseconds timeout);
    // Non-streaming only: returns the complete native object/array on success.
    // Call instead of next(). Throws std::logic_error on a streaming request;
    // use next() to keep streaming deltas.
    event result();
    void cancel();
private:
    std::shared_ptr<detail::request_state> state;
};

// Model state/progress events. The first payload is a "snapshot" of the
// catalog. A subscriber that falls max_subscriber_events behind loses the
// queued events and receives one "resync" snapshot instead. Stopping the
// engine ends it (cancelled/stopped). Unsubscribing never affects models.
class subscription {
public:
    explicit subscription(std::shared_ptr<detail::subscriber_state> state);
    ~subscription();
    subscription(const subscription &) = delete;
    subscription & operator=(const subscription &) = delete;
    event next();
    event next_for(std::chrono::milliseconds timeout);
private:
    std::shared_ptr<detail::subscriber_state> state;
};

class engine {
public:
    // Operational load/configuration errors are returned in error; nullptr on failure.
    // Single model, loaded before returning; the "model" field of requests is ignored.
    static std::unique_ptr<engine> create(const config & settings, event & error);
    // Catalog of models, loaded on demand (or with load()); nothing is loaded here.
    static std::unique_ptr<engine> create_catalog(const catalog_config & settings, event & error);
    ~engine();
    engine(const engine &) = delete;
    engine & operator=(const engine &) = delete;
    // Synchronous preparation on the submitting thread, decoding on owned threads.
    // JSON and attachments are passed by value and consumed/owned before return.
    // Native /completion schema, including batch prompts and n, without HTTP.
    // Existing JSON contracts, selected by operation, without HTTP paths.
    // With a catalog, the "model" field selects the model; if it is not
    // loaded, the request waits (bounded, cancellable) and is prepared by the
    // loading thread once the model is resident.
    std::unique_ptr<request> submit(operation op, json input = json::object(),
                                    std::vector<attachment> files = {});
    std::unique_ptr<request> completion(json input, std::vector<attachment> files = {});
    // Catalog snapshot: id, aliases, tags, status (unloaded, loading, loaded,
    // sleeping, unloading, failed), progress/error, active and waiting counts.
    json catalog() const;
    std::unique_ptr<subscription> subscribe();
    // Loads a model, waiting for a slot like a request. Succeeds once it is
    // resident; cancelling the handle does not cancel a load already started.
    std::unique_ptr<request> load(const std::string & model);
    // Explicit unload: closes admissions, cancels its requests and waiters,
    // waits for them to stop, then frees resources. Blocks until done.
    event unload(const std::string & model);
    // Concurrent, idempotent. Closes admissions, cancels, wakes readers and joins.
    // Surviving requests drain buffered payloads then see their sole terminal result;
    // every subsequent next() returns that same terminal result immediately.
    // Submissions after stop return an explicitly cancelled request.
    void stop();
private:
    engine();
    std::unique_ptr<detail::engine_impl> impl;
};
} // namespace llama_engine
