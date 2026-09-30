#pragma once

#include <nlohmann/json.hpp>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
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

// Configuration of one model. Typed fields are shortcuts with conservative
// defaults for embedding (CPU, small context, no fitting or warmup); std::nullopt
// or an empty value keeps llama.cpp's default instead. Every other loading and
// inference setting is passed in options, named as in preset (INI) files: the
// argument name without leading dashes, its negated form or its LLAMA_ARG_* name
// ("ctx-size", "flash-attn", "temp", "hf-repo", ...). Options of the host
// application (HTTP, UI, tools, logging, process-wide state) or of the catalog
// (alias, models-dir, ...) are rejected, as is an option that repeats a typed
// field. Invalid configurations fail with invalid_config.
struct config {
    std::string model_path; // or a model option: "model", "hf-repo", "model-url", "docker-repo"
    std::optional<int> context_size = 512;
    std::optional<int> parallel = 1;
    std::optional<int> threads = 2;
    std::optional<int> gpu_layers = 0;      // 0 also keeps the multimodal projector on CPU
    std::optional<int> batch_size = 128;
    std::optional<int> micro_batch_size = 128;
    std::optional<bool> fit = false;        // fit unset parameters to device memory
    std::optional<bool> warmup = false;
    std::string chat_template;
    std::string mmproj_path;
    bool embeddings = false;
    int pooling_type = -1; // llama_pooling_type: -1 = model default
    std::string slot_save_path; // empty disables persistent slot actions
    std::vector<std::string> lora_paths;
    // Free the model after this many idle seconds and reload it on the next
    // request (-1 disables). A failed reload is reported as wake_failed.
    int sleep_idle_seconds = -1;
    std::map<std::string, std::string> options;
    size_t max_tasks = 64;          // includes queued, active and cancelling tasks
    size_t max_events = 256;        // per request, before JSON conversion
    size_t max_request_bytes = 16 * 1024 * 1024;
    json generation_defaults = json::object();

    // Only options, over llama.cpp's defaults (as the llama-server command line
    // would configure a model); engine limits keep their defaults.
    static config from_options(std::map<std::string, std::string> options);
};

// Owner of a named option: a model's configuration (engine, accepted in
// config::options), the host application (HTTP, UI, tools, logging, terminal,
// process-wide state) or the catalog (alias, models-dir, ...). Lets a host that
// reads a whole command line or preset keep the options it passes to the engine.
enum class option_scope { engine, host, catalog, unknown };
// Any spelling of config::options, with or without leading dashes.
option_scope find_option_scope(const std::string & name);

// Catalog id that create() gives a model: its file name, or its repository.
// Throws std::invalid_argument when the configuration is invalid.
std::string model_id(const config & settings);

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
    model_entry(std::string id = {}, std::vector<std::string> aliases = {}, std::vector<std::string> tags = {},
                config settings = {})
        : id(std::move(id)), aliases(std::move(aliases)), tags(std::move(tags)), settings(std::move(settings)) {}

    std::string id;
    std::vector<std::string> aliases;
    std::vector<std::string> tags;  // informational
    config settings;                // loading configuration and per-model limits
    // Set by read_catalog, informational for the engine:
    std::string source;             // "cache", "models_dir" or "preset"
    bool hidden = false;            // cache entry deduplicated by a preset
    bool load_on_startup = false;   // preset "load-on-startup"
    std::map<std::string, std::string> host_options; // per-model options owned by the host (e.g. stop-timeout)
    // "text", then "image" and "audio" when the model's projector, found locally
    // (files or cache, without network), supports them.
    std::vector<std::string> input_modalities;
    // Configuration error found while reading the sources: the model stays in
    // the catalog and fails to load with this message (invalid_config).
    std::string error;
};

// Explicit catalog sources; nothing else is discovered and nothing is written.
struct catalog_sources {
    bool cache = false;             // models in the Hugging Face cache (LLAMA_CACHE, HF_HUB_CACHE, ...)
    std::string models_dir;         // one model per GGUF file or subdirectory
    std::string presets;            // INI file; its "*" section applies to every model
    std::map<std::string, std::string> options;  // over every model, e.g. the host's command line
    std::map<std::string, std::string> defaults; // under every model, e.g. the host's environment
    bool skip_conflicting_aliases = false;       // drop them with a warning instead of failing (reloads)
};

// Reads the sources into catalog entries with llama-server's rules: a models_dir
// model replaces a cached one of the same name, an INI section of that name is
// merged into it; defaults apply under each model, then the "*" section, and
// options over all.
// Engine options become each entry's settings (config::from_options), host
// options its host_options. No network access.
event read_catalog(const catalog_sources & sources, std::vector<model_entry> & models);

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
    // When set, create_catalog() reads these sources (read_catalog) and adds their
    // entries to models; reload() and successful downloads read them again.
    std::optional<catalog_sources> sources;
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
    // sleeping, unloading, failed, downloading), progress/error, active and
    // waiting counts, source, hidden and input_modalities when set, and the
    // loaded model's metadata ("info") while it is resident. A status event
    // announcing "loaded" carries the same info.
    json catalog() const;
    std::unique_ptr<subscription> subscribe();
    // Loads a model, waiting for a slot like a request. Succeeds once it is
    // resident; cancelling the handle does not cancel a load already started.
    std::unique_ptr<request> load(const std::string & model);
    // Explicit unload: closes admissions, cancels its requests and waiters,
    // waits for them to stop, then frees resources. Blocks until done.
    event unload(const std::string & model);
    // Replaces the catalog (not for engines made with create()). Removed models
    // are unloaded and their requests and waiters end with model_not_found;
    // models whose settings changed are unloaded and reloaded on demand with
    // the new settings (waiters are kept); others keep running. An invalid list
    // leaves the catalog unchanged. Subscribers receive a "reload" snapshot.
    event update_catalog(std::vector<model_entry> models);
    // Reads the catalog sources again and applies them like update_catalog
    // (conflicting aliases are dropped with a warning); entries given in
    // catalog_config::models are kept.
    event reload();
    // Downloads a Hugging Face repository ("user/model[:quant]") into the cache
    // with the resolution rules of hf-repo (model, projector, draft sidecars);
    // options are engine options such as "hf-token". The repository metadata is
    // requested before returning. Meanwhile the catalog lists the repository as
    // "downloading", with progress in subscriptions; afterwards the entry goes
    // and, with sources, the catalog is read again before the "download" event
    // is published, so the downloaded model is listed by then. The request ends with
    // success, download_failed or, if cancelled, cancelled (incomplete files are
    // deleted). Without network acquisition: capability_unavailable.
    std::unique_ptr<request> download(const std::string & repo, std::map<std::string, std::string> options = {});
    // Removes a model read from the cache: cancels its download or unloads it
    // (its requests and waiters end), deletes its cached files and its entry.
    // Models from other sources are not removable (invalid_request).
    event remove(const std::string & model);
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
