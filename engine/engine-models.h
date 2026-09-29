#pragma once

#include "engine-runtime.h"
#include "engine-scheduler.h"

#include <condition_variable>
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
};

struct backend_hooks {
    std::function<void(const ::json & progress)> progress; // loading thread or decoder (wake)
    std::function<void(bool sleeping)> sleeping;           // decoder thread
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

enum class model_status { unloaded, loading, loaded, sleeping, unloading, failed };
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

    void start(); // housekeeping thread: unloads, joins and deadlines
    std::shared_ptr<request_state> submit(operation op, const json & input, std::vector<attachment> files);
    std::shared_ptr<request_state> load(const std::string & model);
    event unload(const std::string & model);
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
        bool asleep = false;          // sleep reported before the load completed
        int active = 0;               // admitted requests not yet finished
        int64_t last_used = 0;
        uint64_t generation = 0;      // one per load; late callbacks of older ones are ignored
        std::string error;
        json progress;
        std::list<std::shared_ptr<waiter>> waiters;
    };
    struct pending_stop {
        std::string model;
        uint64_t generation;
        std::shared_ptr<model_backend> backend;
        event reason;
    };
    using lock_t = std::unique_lock<std::mutex>;

    record * resolve(const std::string & name);
    std::shared_ptr<request_state> enqueue(lock_t & lk, record & r, std::shared_ptr<request_state> state,
                                           ::json data, operation op, std::vector<attachment> files, bool load_only);
    void schedule(lock_t & lk);
    void start_load(record & r); // caller holds mutex
    void run_load(const std::string & name, uint64_t generation, std::shared_ptr<model_backend> backend);
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
    std::map<std::string, record> records; // keys and entries are immutable after construction
    load_queue queue {mutex};
    size_t n_waiting = 0;
    bool stopped = false;
    std::deque<pending_stop> stops;
    std::vector<std::thread> retired;
    std::vector<std::weak_ptr<subscriber_state>> subscribers;
    std::thread housekeeper;
};

} } // namespace llama_engine::detail
