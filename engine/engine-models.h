#pragma once

#include "engine-runtime.h"
#include "engine-scheduler.h"

#include <atomic>
#include <condition_variable>
#include <optional>
#include <list>
#include <map>
#include <set>
#include <thread>

namespace llama_engine { namespace detail {

// Resources of one catalog entry, as seen by the model manager. The production
// backend owns a server_context; tests substitute doubles to force races.
struct model_backend {
    virtual ~model_backend() = default;
    // Called on the loading thread; false with a message on failure.
    virtual bool load(std::string & error) = 0;
    // Any thread: a load in progress fails at its next progress report.
    virtual void cancel_load() = 0;
    // Admission; preparation runs on the calling thread.
    virtual void submit(const std::shared_ptr<request_state> & state, const ::json & data,
                        operation op, const std::vector<attachment> & files) = 0;
    // Ends its requests with reason, joins its threads and frees its resources.
    virtual void stop(const event & reason) = 0;
    // Metadata of the loaded model (loading thread, after a successful load).
    virtual json info() { return nullptr; }
};

struct backend_hooks {
    std::function<void(const ::json & progress)> progress; // loading thread or decoder (wake)
    std::function<void(bool sleeping)> sleeping;           // decoder thread
    // Settings of the embedding host that the model's requests and properties
    // read (HTTP-facing defaults, model name), applied after the engine options.
    std::function<void(common_params & params)> host_params;
};
using backend_factory = std::function<std::shared_ptr<model_backend>(const model_entry &, backend_hooks)>;

std::shared_ptr<model_backend> make_context_backend(const model_entry & entry, backend_hooks hooks);

struct subscriber_state {
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<event> events;
    size_t capacity = 256;
    bool closed = false;
    event terminal;

    // snapshot() is only called on overflow, to build the resync event
    void publish(json data, const std::function<json()> & snapshot);
    void close(event end);
    event read(std::chrono::milliseconds timeout);
};

enum class model_status { unloaded, loading, loaded, sleeping, unloading, failed, downloading };
const char * to_string(model_status status);

// Catalog, residency and admissions of several models in one engine.
//
//   unloaded/failed ──► loading ──► loaded ◄──► sleeping
//          ▲               │  │        │           │
//          └───failed──────┘  │        └─ unloading ◄┘ (explicit unload or eviction)
//          ▲                  └─────────► unloading (explicit unload during load)
//          └──────────────────────────────────┘ resources freed
//
// Loading, resident, sleeping and unloading models count against max_loaded.
// Waiting requests share one queue entry per model (load_queue), are served in
// arrival order, bounded in number and time, and cancellable.
class model_manager : public std::enable_shared_from_this<model_manager> {
public:
    model_manager(catalog_config settings, bool single, backend_factory factory);
    ~model_manager();
    static bool validate(const catalog_config & settings, std::string & error);
    static bool validate_models(const std::vector<model_entry> & models, std::string & error);

    void start(); // housekeeping thread: unloads, joins and deadlines
    std::shared_ptr<request_state> submit(operation op, const json & input, std::vector<attachment> files);
    // Native JSON already parsed by a transport (see submit_native in engine-runtime.h);
    // autoload overrides catalog_config::autoload for this request.
    std::shared_ptr<request_state> submit_native(operation op, ::json data, std::vector<attachment> files,
                                                 std::optional<bool> autoload = std::nullopt);
    // Entries in the catalog (with alias resolution for entry()).
    std::vector<model_entry> entries();
    std::optional<model_entry> entry(const std::string & name);
    // Applied to every entry read from the sources, at creation and on reload.
    void set_entry_adjust(std::function<void(model_entry &)> adjust);
    std::shared_ptr<request_state> load(const std::string & model);
    // Status of a model by name or alias ("" when unknown).
    std::string status_of(const std::string & model);
    event unload(const std::string & model);
    // Replaces the entries (see engine::update_catalog).
    event update(std::vector<model_entry> models);
    // Catalog sources re-read by reload() and after downloads, with entries given explicitly.
    void set_sources(catalog_sources sources, std::vector<model_entry> fixed);
    event reload();
    std::shared_ptr<request_state> download(const std::string & repo, const std::map<std::string, std::string> & options);
    event remove(const std::string & model);
    json catalog();
    std::shared_ptr<subscriber_state> subscribe();
    void stop();

private:
    struct waiter {
        std::string model;
        std::shared_ptr<request_state> state;
        ::json data;
        operation op = operation::completion;
        std::vector<attachment> files;
        bool load_only = false;
        std::chrono::steady_clock::time_point deadline;
    };
    struct record {
        model_entry entry;
        std::set<std::string> aliases;
        model_status status = model_status::unloaded;
        std::shared_ptr<model_backend> backend;
        std::thread loader;
        bool unload_requested = false;
        bool removed = false;         // left the catalog; erased once idle
        std::shared_ptr<std::atomic<bool>> download_cancel; // set while downloading
        bool asleep = false;          // sleep reported before the load completed
        int active = 0;               // admitted requests not yet finished
        int64_t last_used = 0;
        uint64_t generation = 0;      // unique per load (manager-wide); late callbacks of older ones are ignored
        std::string error;
        json progress;
        json info;                    // backend metadata while resident
        std::list<std::shared_ptr<waiter>> waiters;
    };
    struct pending_stop {
        std::string model;
        uint64_t generation;
        std::shared_ptr<model_backend> backend;
        event reason;
    };
    using lock_t = std::unique_lock<std::mutex>;

    record * resolve(const std::string & name);     // caller holds mutex; live entries only
    // Admission once the input is prepared for the model's limits.
    std::shared_ptr<request_state> admit(const std::string & name, std::shared_ptr<request_state> state,
                                         operation op, std::vector<attachment> files, std::optional<bool> autoload,
                                         const std::function<bool(const config & limits, ::json & data)> & prepare);
    record * find_record(const std::string & name); // caller holds mutex; tombstones too
    void close_admissions(record & r, event reason); // caller holds mutex
    std::shared_ptr<request_state> enqueue(lock_t & lk, record & r, std::shared_ptr<request_state> state,
                                           ::json data, operation op, std::vector<attachment> files, bool load_only);
    void schedule(lock_t & lk);
    void start_load(record & r); // caller holds mutex
    void run_load(const std::string & name, uint64_t generation, std::shared_ptr<model_backend> backend,
                  std::string config_error);
    void run_download(const std::string & repo, uint64_t generation, std::shared_ptr<request_state> state,
                      std::shared_ptr<struct download_job> job);
    void begin_unload(record & r, event reason); // caller holds mutex
    void take_waiters(lock_t & lk, record & r, std::vector<std::shared_ptr<waiter>> & out);
    void drop_waiter(const std::shared_ptr<waiter> & w);
    void release(const std::string & name, uint64_t generation);
    void on_progress(const std::string & name, uint64_t generation, const ::json & progress);
    void on_sleep(const std::string & name, uint64_t generation, bool sleeping);
    std::function<void()> release_hook(const record & r);
    json describe(const record & r) const;
    json catalog_locked() const;
    void publish(json data);                // caller holds mutex
    void publish_status(const record & r);  // caller holds mutex
    void housekeeping();

    const catalog_config settings;
    const bool single;
    const backend_factory factory;

    std::mutex stop_mutex;
    std::mutex mutex;
    std::condition_variable changed;
    std::map<std::string, record> records; // guarded by mutex; removed entries are erased once idle
    uint64_t next_generation = 0;
    std::optional<catalog_sources> sources;
    std::vector<model_entry> fixed; // entries given explicitly, kept by reload()
    std::function<void(model_entry &)> adjust; // set before start()
    std::mutex reload_mutex;        // one reload at a time
    load_queue queue {mutex};
    size_t n_waiting = 0;
    bool stopped = false;
    std::deque<pending_stop> stops;
    std::vector<std::thread> retired;
    std::vector<std::weak_ptr<subscriber_state>> subscribers;
    std::thread housekeeper;
};

// The manager behind engine::create_catalog(), for hosts that choose the backend
// (tests, instrumented backends) and adjust the entries read from the sources.
// nullptr with error on an invalid catalog; started on success.
std::shared_ptr<model_manager> make_catalog_manager(const catalog_config & settings, backend_factory factory,
                                                    std::function<void(model_entry &)> adjust, event & error);

} } // namespace llama_engine::detail
