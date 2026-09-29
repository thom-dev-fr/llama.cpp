#include "engine-models.h"
#include "engine-context.h"
#include "engine-options.h"
#include "download.h"
#include "engine-catalog.h"
#include "arg.h"
#include "server-common.h"

#include <filesystem>

namespace llama_engine { namespace detail {

using clock = std::chrono::steady_clock;

const char * to_string(model_status status) {
    switch (status) {
        case model_status::unloaded:  return "unloaded";
        case model_status::loading:   return "loading";
        case model_status::loaded:    return "loaded";
        case model_status::sleeping:  return "sleeping";
        case model_status::unloading: return "unloading";
        case model_status::failed:    return "failed";
        case model_status::downloading: return "downloading";
    }
    return "unknown";
}

//
// production backend: one server_context (decoder, slots, caches) per model
//

namespace {
struct context_backend : model_backend {
    model_entry entry;
    backend_hooks hooks;
    std::unique_ptr<server_context> context {new server_context};
    std::shared_ptr<runtime> run = context->runtime;

    context_backend(model_entry entry, backend_hooks hooks) : entry(std::move(entry)), hooks(std::move(hooks)) {}

    bool load(std::string & error) override {
        run->limits = entry.settings;
        auto progress = hooks.progress;
        auto sleeping = hooks.sleeping;
        context->set_state_callback([progress, sleeping](server_state state, ::json payload) {
            if (state == SERVER_STATE_LOADING && progress) {
                progress(payload);
            } else if (state == SERVER_STATE_SLEEPING && sleeping) {
                sleeping(true);
            } else if (state == SERVER_STATE_READY && sleeping) {
                sleeping(false); // emitted once the reload after sleeping succeeded
            }
        });
        common_params params = build_params(entry.settings);
        download_progress download(this);
        resolve_resources(params, &download); // may download; cancel_load() aborts it
        if (!context->load_model(params)) {
            error = "Failed to load model: " + params.model.get_name();
            return false;
        }
        context->start();
        return true;
    }

    void cancel_load() override {
        cancelled = true;
        context->cancel_load();
    }

    std::atomic<bool> cancelled {false};

    // Downloads during a load report as loading progress, throttled like the router's.
    struct download_progress : common_download_callback {
        context_backend * self;
        std::atomic<int64_t> last {0}; // files download in parallel
        explicit download_progress(context_backend * self) : self(self) {}
        void report(const common_download_progress & p, bool force) {
            const int64_t now = ggml_time_ms();
            if (!self->hooks.progress || (!force && now - last.load(std::memory_order_relaxed) < 100)) {
                return;
            }
            last.store(now, std::memory_order_relaxed);
            self->hooks.progress({{"stage", "download"}, {"url", p.url}, {"downloaded", p.downloaded},
                                  {"total", p.total}, {"cached", p.cached}});
        }
        void on_start(const common_download_progress & p) override { report(p, true); }
        void on_update(const common_download_progress & p) override { report(p, false); }
        void on_done(const common_download_progress & p, bool) override { report(p, true); }
        bool is_cancelled() const override { return self->cancelled.load(); }
    };

    void submit(const std::shared_ptr<request_state> & state, const ::json & data,
                operation op, const std::vector<attachment> & files) override {
        submit_native(run, state, data, op, files);
    }

    void stop(const event & reason) override {
        request_stop(run, reason);
        detail::stop(run);
        context.reset(); // run->stopped rejects any later submission
    }
};
} // namespace

std::shared_ptr<model_backend> make_context_backend(const model_entry & entry, backend_hooks hooks) {
    return std::make_shared<context_backend>(entry, std::move(hooks));
}

//
// subscribers
//

void subscriber_state::publish(json data, const std::function<json()> & snapshot) {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed) {
        return;
    }
    if (events.size() >= capacity) {
        // a slow subscriber loses the queued events, never silently: one
        // snapshot that already includes this change replaces them
        events.clear();
        events.push_back({event_type::payload, {{"type", "resync"}, {"models", snapshot()}}, {}, {}});
    } else {
        events.push_back({event_type::payload, std::move(data), {}, {}});
    }
    ready.notify_all();
}

void subscriber_state::close(event end) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!closed) {
        closed = true;
        terminal = std::move(end);
        ready.notify_all();
    }
}

event subscriber_state::read(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex);
    const auto available = [&] { return !events.empty() || closed; };
    if (timeout == std::chrono::milliseconds::max()) {
        ready.wait(lock, available);
    } else if (!ready.wait_for(lock, timeout, available)) {
        return {event_type::timeout, nullptr, {}, {}};
    }
    if (events.empty()) {
        return terminal;
    }
    auto item = std::move(events.front());
    events.pop_front();
    return item;
}

//
// model manager
//

model_manager::model_manager(catalog_config settings_, bool single_, backend_factory factory_)
        : settings(std::move(settings_)), single(single_), factory(std::move(factory_)) {
    for (const auto & entry : settings.models) {
        record r;
        r.entry = entry;
        r.aliases.insert(entry.aliases.begin(), entry.aliases.end());
        records.emplace(entry.id, std::move(r));
    }
    queue.max_models = [this]() { return settings.max_loaded; };
    queue.each_model = [this](const load_queue::usage_visitor & visit) {
        for (const auto & [name, r] : records) {
            model_usage usage;
            usage.running = r.status == model_status::loading || r.status == model_status::loaded ||
                            r.status == model_status::sleeping || r.status == model_status::unloading;
            usage.ready_or_sleep = r.status == model_status::loaded || r.status == model_status::sleeping;
            usage.busy      = r.active > 0;
            usage.stopping  = r.status == model_status::unloading;
            usage.last_used = r.last_used;
            visit(name, usage);
        }
    };
    queue.evict = [this](const std::string & victim) {
        // called by queue.tick() with the lock held; the backend stops on the housekeeper
        begin_unload(records.at(victim), {event_type::cancelled, nullptr, "evicted", "Model evicted"});
    };
}

model_manager::~model_manager() {
    stop();
}

bool model_manager::validate(const catalog_config & settings, std::string & error) {
    if (settings.max_waiting == 0 || settings.max_subscriber_events == 0 ||
        settings.wait_timeout <= std::chrono::milliseconds::zero()) {
        error = "Invalid catalog configuration";
        return false;
    }
    return validate_models(settings.models, error);
}

bool model_manager::validate_models(const std::vector<model_entry> & models, std::string & error) {
    std::set<std::string> names;
    for (const auto & entry : models) {
        std::string message;
        // an entry read with a configuration error stays listed and fails to load
        if (entry.id.empty() || (entry.error.empty() && !valid_config(entry.settings, message))) {
            error = "Invalid configuration for model '" + entry.id + "'" + (message.empty() ? "" : ": " + message);
            return false;
        }
        if (!names.insert(entry.id).second) {
            error = "Duplicate model name '" + entry.id + "'";
            return false;
        }
    }
    for (const auto & entry : models) {
        for (const auto & alias : entry.aliases) {
            if (alias.empty() || !names.insert(alias).second) {
                error = "Alias '" + alias + "' conflicts with another model name or alias";
                return false;
            }
        }
    }
    return true;
}

void model_manager::start() {
    housekeeper = std::thread([this] { housekeeping(); });
}

model_manager::record * model_manager::resolve(const std::string & name) {
    if (single) {
        return &records.begin()->second;
    }
    auto it = find_model(records, name, [](const record & r) -> const std::set<std::string> & { return r.aliases; });
    return it == records.end() || it->second.removed ? nullptr : &it->second;
}

model_manager::record * model_manager::find_record(const std::string & name) {
    auto it = records.find(name);
    return it == records.end() ? nullptr : &it->second;
}

std::function<void()> model_manager::release_hook(const record & r) {
    std::weak_ptr<model_manager> weak = shared_from_this();
    return [weak, name = r.entry.id, generation = r.generation] {
        if (auto owner = weak.lock()) {
            owner->release(name, generation);
        }
    };
}

std::shared_ptr<request_state> model_manager::submit(operation op, const json & input, std::vector<attachment> files) {
    auto state = std::make_shared<request_state>();
    std::string name;
    if (!single) {
        if (input.is_object() && input.contains("model") && input.at("model").is_string()) {
            name = input.at("model").get<std::string>();
        }
        if (name.empty()) {
            state->finish({event_type::error, nullptr, "invalid_request", "model name is missing from the request"});
            return state;
        }
    }
    const auto not_found = [&] {
        state->finish({event_type::error, nullptr, "model_not_found", "model '" + name + "' not found"});
        return state;
    };
    config limits;
    {
        lock_t lk(mutex);
        record * r = resolve(name);
        if (!r) {
            lk.unlock();
            return not_found();
        }
        limits = r->entry.settings;
    }
    ::json data;
    if (!prepare_input(limits, *state, input, files, op, data)) {
        return state;
    }
    lock_t lk(mutex);
    if (stopped) {
        lk.unlock();
        state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return state;
    }
    record * r = resolve(name); // the catalog may have changed during preparation
    if (!r) {
        lk.unlock();
        return not_found();
    }
    r->last_used = ggml_time_ms();
    if (r->status == model_status::loaded || r->status == model_status::sleeping) {
        // admitted now: busy models are never evicted; a sleeping one wakes up on preparation
        state->attach_finish_hook(release_hook(*r));
        r->active++;
        auto backend = r->backend;
        lk.unlock();
        backend->submit(state, data, op, files);
        return state;
    }
    if (r->status == model_status::downloading) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "model_downloading", "model is being downloaded"});
        return state;
    }
    if (!settings.autoload && r->status != model_status::loading) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "model_not_loaded", "model is not loaded"});
        return state;
    }
    return enqueue(lk, *r, state, std::move(data), op, std::move(files), false);
}

std::shared_ptr<request_state> model_manager::load(const std::string & model) {
    auto state = std::make_shared<request_state>();
    lock_t lk(mutex);
    record * r = resolve(model);
    if (!r || (single && !model.empty() && model != r->entry.id && !r->aliases.count(model))) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "model_not_found", "model '" + model + "' not found"});
        return state;
    }
    if (stopped) {
        lk.unlock();
        state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return state;
    }
    if (r->status == model_status::loaded || r->status == model_status::sleeping) {
        lk.unlock();
        state->finish({event_type::success, nullptr, {}, {}});
        return state;
    }
    if (r->status == model_status::downloading) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "model_downloading", "model is being downloaded"});
        return state;
    }
    return enqueue(lk, *r, state, nullptr, operation::completion, {}, true);
}

std::shared_ptr<request_state> model_manager::enqueue(lock_t & lk, record & r, std::shared_ptr<request_state> state,
                                                      ::json data, operation op, std::vector<attachment> files, bool load_only) {
    if (n_waiting >= settings.max_waiting) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "capacity_exceeded", "Too many requests waiting for a model"});
        return state;
    }
    auto w = std::make_shared<waiter>();
    w->model     = r.entry.id;
    w->state     = state;
    w->op        = op;
    w->files     = std::move(files);
    w->load_only = load_only;
    w->deadline  = settings.wait_timeout >= std::chrono::hours(24 * 365)
        ? clock::time_point::max() : clock::now() + settings.wait_timeout;
    // the stream flag is final after preparation; readers may look at it before
    state->stream = !load_only && json_value(data, "stream", false);
    w->data = std::move(data);
    std::weak_ptr<model_manager> weak = shared_from_this();
    state->cancel_work = [weak, w] {
        if (auto owner = weak.lock()) {
            owner->drop_waiter(w);
        }
    };
    r.waiters.push_back(w);
    n_waiting++;
    queue.join(lk, r.entry.id);
    publish_status(r);
    schedule(lk);
    changed.notify_all(); // new deadline for the housekeeper
    return state;
}

void model_manager::schedule(lock_t & lk) {
    if (stopped) {
        return;
    }
    queue.tick(lk);
    // first come, first served: only the head of the queue may start a load
    const std::string head = queue.front(lk);
    if (head.empty()) {
        return;
    }
    record & r = records.at(head);
    if (r.status != model_status::unloaded && r.status != model_status::failed) {
        return; // loading, or its previous instance is still being freed
    }
    if (queue.try_claim(lk, head)) {
        start_load(r);
        queue.claim_done(lk, head, true);
    }
}

void model_manager::start_load(record & r) {
    r.generation = ++next_generation;
    r.status           = model_status::loading;
    r.unload_requested = false;
    r.asleep           = false;
    r.active           = 0;
    r.error.clear();
    r.progress         = nullptr;
    r.last_used        = ggml_time_ms();
    std::weak_ptr<model_manager> weak = shared_from_this();
    backend_hooks hooks;
    hooks.progress = [weak, name = r.entry.id, generation = r.generation](const ::json & progress) {
        if (auto owner = weak.lock()) {
            owner->on_progress(name, generation, progress);
        }
    };
    hooks.sleeping = [weak, name = r.entry.id, generation = r.generation](bool sleeping) {
        if (auto owner = weak.lock()) {
            owner->on_sleep(name, generation, sleeping);
        }
    };
    // an entry read with a configuration error fails on its loading thread, like a load
    r.backend = r.entry.error.empty() ? factory(r.entry, std::move(hooks)) : nullptr;
    if (r.loader.joinable()) {
        retired.push_back(std::move(r.loader));
    }
    r.loader = std::thread([this, name = r.entry.id, generation = r.generation, backend = r.backend, error = r.entry.error] {
        run_load(name, generation, backend, error);
    });
    publish_status(r);
}

void model_manager::take_waiters(lock_t & lk, record & r, std::vector<std::shared_ptr<waiter>> & out) {
    for (auto & w : r.waiters) {
        queue.leave(lk, r.entry.id);
        n_waiting--;
        out.push_back(std::move(w));
    }
    r.waiters.clear();
}

void model_manager::run_load(const std::string & name, uint64_t generation, std::shared_ptr<model_backend> backend,
                             std::string config_error) {
    std::string error = std::move(config_error);
    std::string category = backend ? "load_failed" : "invalid_config";
    bool ok = false;
    try {
        if (backend) {
            ok = backend->load(error);
        }
    } catch (const common_download_unavailable & e) {
        error    = e.what();
        category = "capability_unavailable";
    } catch (const std::exception & e) {
        error = e.what();
    }
    if (!ok && backend) {
        backend->stop({event_type::cancelled, nullptr, "stopped", "Engine stopped"}); // partial resources
    }
    std::vector<std::shared_ptr<waiter>> waiters;
    std::vector<std::shared_ptr<waiter>> admitted;
    std::shared_ptr<model_backend> resident;
    event failure;
    {
        lock_t lk(mutex);
        record & r = records.at(name); // a loading entry is never erased
        if (r.loader.joinable() && r.loader.get_id() == std::this_thread::get_id()) {
            retired.push_back(std::move(r.loader)); // joined by the housekeeper or stop()
            changed.notify_all();
        }
        if (stopped || r.generation != generation) {
            return; // stop() frees the backend after joining this thread
        }
        if (r.unload_requested) {
            // waiters kept by a catalog update load the next instance: release this claim
            queue.claim_done(lk, name, false);
            if (ok) {
                stops.push_back({name, generation, std::move(r.backend), {event_type::cancelled, nullptr, "unloaded", "Model unloaded"}});
            } else {
                r.backend.reset();
                r.status = model_status::unloaded;
                publish_status(r);
                schedule(lk);
            }
            changed.notify_all();
            return;
        }
        take_waiters(lk, r, waiters);
        if (!ok) {
            r.backend.reset();
            r.status = model_status::failed;
            r.error  = error.empty() ? "Failed to load model: " + name : error;
            failure  = {event_type::error, nullptr, category, r.error};
        } else {
            r.status    = r.asleep ? model_status::sleeping : model_status::loaded;
            r.last_used = ggml_time_ms();
            resident    = r.backend;
            for (auto & w : waiters) {
                if (!w->load_only && w->state->attach_finish_hook(release_hook(r))) {
                    r.active++; // the model is busy before the queue entry is gone
                    admitted.push_back(w);
                }
            }
        }
        publish_status(r);
        schedule(lk);
        changed.notify_all();
    }
    // outside the lock: finishing may run hooks, preparation may be long
    for (auto & w : waiters) {
        if (!ok) {
            w->state->finish(failure);
        } else if (w->load_only) {
            w->state->finish({event_type::success, nullptr, {}, {}});
        }
    }
    for (auto & w : admitted) {
        resident->submit(w->state, w->data, w->op, w->files);
    }
}

void model_manager::begin_unload(record & r, event reason) {
    r.status = model_status::unloading;
    stops.push_back({r.entry.id, r.generation, std::move(r.backend), std::move(reason)});
    publish_status(r);
    changed.notify_all();
}

event model_manager::unload(const std::string & model) {
    std::vector<std::shared_ptr<waiter>> waiters;
    lock_t lk(mutex);
    record * r = resolve(model);
    if (!r || (single && !model.empty() && model != r->entry.id && !r->aliases.count(model))) {
        return {event_type::error, nullptr, "model_not_found", "model '" + model + "' not found"};
    }
    if (stopped) {
        return {event_type::cancelled, nullptr, "stopped", "Engine stopped"};
    }
    const event reason {event_type::cancelled, nullptr, "unloaded", "Model unloaded"};
    switch (r->status) {
        case model_status::downloading: {
            // as llama-server: unloading a model being downloaded cancels the download
            r->download_cancel->store(true);
            const std::string id = r->entry.id;
            changed.wait(lk, [&] { const record * cur = find_record(id); return stopped || !cur || cur->removed; });
            return {event_type::success, nullptr, {}, {}};
        }
        case model_status::unloaded:
        case model_status::failed:
            return {event_type::error, nullptr, "model_not_loaded", "model is not loaded"};
        case model_status::unloading:
            break; // already in progress, wait for it below
        case model_status::loading:
            // admissions close now; the load stops at its next progress report
            r->unload_requested = true;
            r->status = model_status::unloading;
            if (r->backend) {
                r->backend->cancel_load();
            }
            take_waiters(lk, *r, waiters);
            publish_status(*r);
            break;
        case model_status::loaded:
        case model_status::sleeping:
            take_waiters(lk, *r, waiters);
            begin_unload(*r, reason);
            break;
    }
    const uint64_t generation = r->generation;
    const std::string id = r->entry.id;
    schedule(lk);
    lk.unlock();
    for (auto & w : waiters) {
        w->state->finish(reason);
    }
    lk.lock();
    changed.wait(lk, [&] {
        const record * cur = find_record(id); // the entry may leave the catalog meanwhile
        return stopped || !cur || cur->generation != generation ||
               (cur->status != model_status::unloading && cur->status != model_status::loading);
    });
    return {event_type::success, nullptr, {}, {}};
}

static bool same_settings(const model_entry & a, const model_entry & b) {
    return a.error == b.error && same_config(a.settings, b.settings);
}

void model_manager::close_admissions(record & r, event reason) {
    switch (r.status) {
        case model_status::loaded:
        case model_status::sleeping:
            begin_unload(r, std::move(reason));
            break;
        case model_status::loading:
            r.unload_requested = true; // the load stops at its next progress report
            r.status = model_status::unloading;
            if (r.backend) { // none for an entry that fails with its configuration error
                r.backend->cancel_load();
            }
            break;
        default:
            break; // not resident, or already being freed
    }
}

event model_manager::update(std::vector<model_entry> models) {
    if (single) {
        return {event_type::error, nullptr, "invalid_request", "the catalog of a single-model engine cannot change"};
    }
    std::string error;
    if (!validate_models(models, error)) {
        return {event_type::error, nullptr, "invalid_config", error};
    }
    std::map<std::string, model_entry> incoming;
    for (auto & m : models) {
        incoming.emplace(m.id, std::move(m));
    }
    std::vector<std::shared_ptr<waiter>> orphans;
    lock_t lk(mutex);
    if (stopped) {
        return {event_type::cancelled, nullptr, "stopped", "Engine stopped"};
    }
    for (auto & [name, r] : records) {
        if (r.removed) {
            continue;
        }
        if (r.status == model_status::downloading) {
            incoming.erase(name); // as llama-server: added by the reload that follows the download
            continue;
        }
        auto it = incoming.find(name);
        if (it == incoming.end()) {
            // requests of a removed model end; its resources are freed as for an unload
            take_waiters(lk, r, orphans);
            r.removed = true;
            close_admissions(r, {event_type::cancelled, nullptr, "unloaded", "Model removed from the catalog"});
            continue;
        }
        if (!same_settings(r.entry, it->second)) {
            // a resident instance keeps the previous settings: free it; waiters load the new ones
            close_admissions(r, {event_type::cancelled, nullptr, "unloaded", "Model configuration changed"});
            if (r.status == model_status::failed) {
                r.status = model_status::unloaded; // a new configuration may load
                r.error.clear();
            }
        }
        r.entry   = std::move(it->second);
        r.aliases = std::set<std::string>(r.entry.aliases.begin(), r.entry.aliases.end());
        incoming.erase(it);
    }
    for (auto & [name, entry] : incoming) {
        record & r = records[name]; // new, or an entry removed earlier and not yet erased
        r.removed = false;
        r.entry   = std::move(entry);
        r.aliases = std::set<std::string>(r.entry.aliases.begin(), r.entry.aliases.end());
        if (r.status == model_status::failed) {
            r.status = model_status::unloaded;
            r.error.clear();
        }
    }
    publish({{"type", "reload"}, {"models", catalog_locked()}});
    schedule(lk);
    changed.notify_all();
    lk.unlock();
    for (auto & w : orphans) {
        w->state->finish({event_type::error, nullptr, "model_not_found",
                          "model '" + w->model + "' was removed from the catalog"});
    }
    return {event_type::success, nullptr, {}, {}};
}

void model_manager::set_sources(catalog_sources sources_, std::vector<model_entry> fixed_) {
    sources = std::move(sources_);
    fixed   = std::move(fixed_);
}

event model_manager::reload() {
    if (!sources) {
        return {event_type::error, nullptr, "invalid_request", "the catalog has no sources to read"};
    }
    std::lock_guard<std::mutex> serial(reload_mutex);
    auto reading = *sources;
    reading.skip_conflicting_aliases = true; // as llama-server reloads
    std::vector<model_entry> models;
    event read = read_catalog(reading, models);
    if (read.type != event_type::success) {
        return read;
    }
    models.insert(models.end(), fixed.begin(), fixed.end());
    return update(std::move(models));
}

// Resolution of one repository, prepared on the calling thread.
struct download_job {
    common_params params;
    common_models_handler handler;
    std::shared_ptr<std::atomic<bool>> cancel = std::make_shared<std::atomic<bool>>(false);
};

std::shared_ptr<request_state> model_manager::download(const std::string & repo,
                                                       const std::map<std::string, std::string> & options) {
    auto state = std::make_shared<request_state>();
    if (single) {
        state->finish({event_type::error, nullptr, "invalid_request", "a single-model engine has no catalog to download into"});
        return state;
    }
    if (!has_acquisition()) {
        state->finish({event_type::error, nullptr, "capability_unavailable",
                       "downloading '" + repo + "' requires network acquisition, which is not available in this build"});
        return state;
    }
    auto job = std::make_shared<download_job>();
    try {
        auto settings_ = config::from_options(options);
        settings_.options["hf-repo"] = repo;
        job->params = build_params(settings_);
        // metadata request, synchronous like llama-server's validation of POST /models
        job->handler = common_models_handler_init(job->params, LLAMA_EXAMPLE_SERVER, download_transport());
        if (common_models_handler_is_preset_repo(job->handler)) {
            throw std::invalid_argument("'" + repo + "' is a preset repository, not a model");
        }
    } catch (const std::invalid_argument & e) {
        state->finish({event_type::error, nullptr, "invalid_request", e.what()});
        return state;
    } catch (const std::exception & e) {
        state->finish({event_type::error, nullptr, "download_failed", e.what()});
        return state;
    }
    lock_t lk(mutex);
    if (stopped) {
        lk.unlock();
        state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return state;
    }
    const record * existing = find_record(repo);
    const bool idle_tombstone = existing && existing->removed && existing->active == 0 && existing->waiters.empty() &&
        !existing->loader.joinable() &&
        (existing->status == model_status::unloaded || existing->status == model_status::failed);
    if (existing && !idle_tombstone) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "invalid_request", "model '" + repo + "' already exists"});
        return state;
    }
    record & r = records[repo];
    r = record(); // new, or an idle entry removed earlier
    r.entry.id         = repo;
    r.entry.source     = "cache";
    r.status           = model_status::downloading;
    r.generation       = ++next_generation;
    r.download_cancel  = job->cancel;
    state->cancel_work = [cancel = job->cancel] { cancel->store(true); };
    r.loader = std::thread([this, repo, generation = r.generation, state, job] {
        run_download(repo, generation, state, job);
    });
    publish_status(r);
    return state;
}

void model_manager::run_download(const std::string & repo, uint64_t generation, std::shared_ptr<request_state> state,
                                 std::shared_ptr<download_job> job) {
    struct progress : common_download_callback {
        model_manager * self;
        std::string repo;
        uint64_t generation;
        std::shared_ptr<std::atomic<bool>> cancel;
        std::atomic<int64_t> last {0}; // files download in parallel
        void report(const common_download_progress & p, bool force) {
            const int64_t now = ggml_time_ms();
            if (!force && now - last.load(std::memory_order_relaxed) < 100) {
                return; // throttled like llama-server's download progress
            }
            last.store(now, std::memory_order_relaxed);
            self->on_progress(repo, generation, {{"stage", "download"}, {"url", p.url}, {"downloaded", p.downloaded},
                                                 {"total", p.total}, {"cached", p.cached}});
        }
        void on_start(const common_download_progress & p) override { report(p, true); }
        void on_update(const common_download_progress & p) override { report(p, false); }
        void on_done(const common_download_progress & p, bool) override { report(p, true); }
        bool is_cancelled() const override { return cancel->load(); }
    } callback;
    callback.self       = this;
    callback.repo       = repo;
    callback.generation = generation;
    callback.cancel     = job->cancel;

    std::string error;
    bool ok = false;
    try {
        common_models_handler_apply(job->handler, job->params, download_transport(), &callback);
        ok = !job->cancel->load();
    } catch (const std::exception & e) {
        error = e.what();
    }
    const bool cancelled = job->cancel->load();
    bool reload_after = false;
    {
        lock_t lk(mutex);
        record * r = find_record(repo);
        if (r && r->generation == generation) {
            if (r->loader.joinable() && r->loader.get_id() == std::this_thread::get_id()) {
                retired.push_back(std::move(r->loader));
            }
            // the placeholder goes; the cache entry comes with the next reading of the sources
            r->status  = model_status::unloaded;
            r->removed = true;
            r->download_cancel.reset();
            publish({{"type", "download"}, {"model", repo},
                     {"result", ok ? "finished" : cancelled ? "cancelled" : "failed"}});
            reload_after = ok && sources && !stopped;
        }
        changed.notify_all();
    }
    if (reload_after) {
        const event reloaded = reload();
        if (reloaded.type != event_type::success) {
            SRV_WRN("reload after downloading '%s' failed: %s\n", repo.c_str(), reloaded.message.c_str());
        }
    }
    if (ok) {
        state->finish({event_type::success, {{"model", repo}}, {}, {}});
    } else if (cancelled) {
        state->finish({event_type::cancelled, nullptr, "cancelled", "Download cancelled"});
    } else {
        state->finish({event_type::error, nullptr, "download_failed",
                       error.empty() ? "failed to download '" + repo + "'" : error});
    }
}

event model_manager::remove(const std::string & model) {
    std::vector<std::shared_ptr<waiter>> orphans;
    lock_t lk(mutex);
    record * r = resolve(model);
    if (!r || single) {
        return {event_type::error, nullptr, "model_not_found", "model '" + model + "' not found"};
    }
    if (r->entry.source != "cache") {
        return {event_type::error, nullptr, "invalid_request", "model '" + model + "' is not removable (not from cache)"};
    }
    const std::string id = r->entry.id;
    if (r->status == model_status::downloading) {
        r->download_cancel->store(true); // the placeholder leaves once the download stops
    } else {
        take_waiters(lk, *r, orphans);
        close_admissions(*r, {event_type::cancelled, nullptr, "unloaded", "Model removed from the cache"});
        r->removed = true;
        publish_status(*r);
    }
    schedule(lk);
    changed.notify_all();
    changed.wait(lk, [&] {
        const record * cur = find_record(id);
        return stopped || !cur || (cur->removed && cur->status != model_status::downloading &&
                                   cur->status != model_status::loading && cur->status != model_status::unloading);
    });
    lk.unlock();
    for (auto & w : orphans) {
        w->state->finish({event_type::error, nullptr, "model_not_found", "model '" + w->model + "' was removed from the cache"});
    }
    // best-effort, like llama-server: a cancelled download may have left no file
    const bool deleted = common_download_remove(id);
    SRV_INF("removing model name=%s from cache (%s)\n", id.c_str(), deleted ? "succeeded" : "partial");
    lk.lock();
    publish({{"type", "remove"}, {"model", id}});
    return {event_type::success, {{"removed_files", deleted}}, {}, {}};
}

void model_manager::drop_waiter(const std::shared_ptr<waiter> & w) {
    lock_t lk(mutex);
    record * found = find_record(w->model);
    if (!found) {
        return;
    }
    record & r = *found;
    for (auto it = r.waiters.begin(); it != r.waiters.end(); ++it) {
        if (*it == w) {
            r.waiters.erase(it);
            queue.leave(lk, r.entry.id);
            n_waiting--;
            // a slot freed for this waiter goes to the next one
            schedule(lk);
            publish_status(r);
            changed.notify_all();
            return;
        }
    }
}

void model_manager::release(const std::string & name, uint64_t generation) {
    lock_t lk(mutex);
    record * r = find_record(name);
    if (!r || r->generation != generation || r->active == 0) {
        return;
    }
    r->active--;
    r->last_used = ggml_time_ms();
    if (r->active == 0) {
        schedule(lk); // an idle model can now make room for a queued one
        changed.notify_all();
    }
}

void model_manager::on_progress(const std::string & name, uint64_t generation, const ::json & progress) {
    lock_t lk(mutex);
    record * r = find_record(name);
    if (!r || r->generation != generation || stopped) {
        return;
    }
    r->progress = json::parse(progress.dump());
    publish({{"type", "progress"}, {"model", name}, {"progress", r->progress}});
}

void model_manager::on_sleep(const std::string & name, uint64_t generation, bool sleeping) {
    lock_t lk(mutex);
    record * r = find_record(name);
    if (!r || r->generation != generation || stopped) {
        return;
    }
    if (r->status == model_status::loading) {
        r->asleep = sleeping;
    } else if (r->status == model_status::loaded || r->status == model_status::sleeping) {
        r->status = sleeping ? model_status::sleeping : model_status::loaded;
        publish_status(*r);
    }
}

json model_manager::describe(const record & r) const {
    json out = {
        {"id",        r.entry.id},
        {"aliases",   r.entry.aliases},
        {"tags",      r.entry.tags},
        {"status",    to_string(r.status)},
        {"active",    r.active},
        {"waiting",   r.waiters.size()},
        {"last_used", r.last_used},
    };
    if (!r.entry.source.empty()) {
        out["source"] = r.entry.source;
    }
    if (r.entry.hidden) {
        out["hidden"] = true;
    }
    if (!r.progress.is_null() && (r.status == model_status::loading || r.status == model_status::downloading)) {
        out["progress"] = r.progress;
    }
    if (!r.error.empty()) {
        out["error"] = r.error;
    }
    return out;
}

json model_manager::catalog_locked() const {
    json out = json::array();
    for (const auto & [name, r] : records) {
        if (!r.removed) {
            out.push_back(describe(r));
        }
    }
    return out;
}

json model_manager::catalog() {
    lock_t lk(mutex);
    return catalog_locked();
}

void model_manager::publish(json data) {
    const auto snapshot = [this] { return catalog_locked(); };
    subscribers.erase(std::remove_if(subscribers.begin(), subscribers.end(), [&](const std::weak_ptr<subscriber_state> & weak) {
        auto sub = weak.lock();
        if (!sub) {
            return true;
        }
        sub->publish(data, snapshot);
        return false;
    }), subscribers.end());
}

void model_manager::publish_status(const record & r) {
    json data = {{"type", "status"}, {"model", r.entry.id}, {"status", to_string(r.status)}, {"waiting", r.waiters.size()}};
    if (r.status == model_status::failed) {
        data["error"] = r.error;
    }
    publish(std::move(data));
}

std::shared_ptr<subscriber_state> model_manager::subscribe() {
    auto sub = std::make_shared<subscriber_state>();
    sub->capacity = settings.max_subscriber_events;
    lock_t lk(mutex);
    if (stopped) {
        sub->close({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return sub;
    }
    sub->events.push_back({event_type::payload, {{"type", "snapshot"}, {"models", catalog_locked()}}, {}, {}});
    subscribers.push_back(sub);
    return sub;
}

void model_manager::housekeeping() {
    lock_t lk(mutex);
    while (true) {
        if (!stops.empty()) {
            auto job = std::move(stops.front());
            stops.pop_front();
            lk.unlock();
            if (job.backend) {
                job.backend->stop(job.reason); // cancels its requests and waits for them
            }
            job.backend.reset();
            lk.lock();
            record * r = find_record(job.model);
            if (r && r->generation == job.generation && r->status == model_status::unloading) {
                r->status   = model_status::unloaded;
                r->progress = nullptr;
                if (!r->removed) {
                    publish_status(*r);
                }
                schedule(lk);
            }
            changed.notify_all();
            continue;
        }
        if (!retired.empty()) {
            auto threads = std::move(retired);
            retired.clear();
            lk.unlock();
            for (auto & t : threads) {
                t.join();
            }
            lk.lock();
            continue;
        }
        if (stopped) {
            return;
        }
        // entries removed from the catalog go once nothing refers to them any more
        for (auto it = records.begin(); it != records.end();) {
            const record & r = it->second;
            const bool idle = r.status == model_status::unloaded || r.status == model_status::failed;
            if (r.removed && idle && r.active == 0 && r.waiters.empty() && !r.loader.joinable()) {
                it = records.erase(it);
            } else {
                ++it;
            }
        }
        // expire waiters; the earliest remaining deadline bounds the next wait
        auto next = clock::time_point::max();
        const auto now = clock::now();
        std::vector<std::shared_ptr<waiter>> expired;
        for (auto & [name, r] : records) {
            for (auto it = r.waiters.begin(); it != r.waiters.end();) {
                if ((*it)->deadline <= now) {
                    expired.push_back(*it);
                    it = r.waiters.erase(it);
                    queue.leave(lk, name);
                    n_waiting--;
                } else {
                    next = std::min(next, (*it)->deadline);
                    ++it;
                }
            }
        }
        if (!expired.empty()) {
            schedule(lk);
            for (const auto & w : expired) {
                publish_status(records.at(w->model));
            }
            lk.unlock();
            for (auto & w : expired) {
                w->state->finish({event_type::error, nullptr, "wait_timeout",
                                  "Timed out waiting for model '" + w->model + "'"});
            }
            lk.lock();
            continue;
        }
        if (next == clock::time_point::max()) {
            changed.wait(lk);
        } else {
            changed.wait_until(lk, next);
        }
    }
}

void model_manager::stop() {
    std::lock_guard<std::mutex> serial(stop_mutex);
    std::vector<std::shared_ptr<waiter>> waiters;
    std::vector<std::thread> loaders;
    {
        lock_t lk(mutex);
        if (stopped && !housekeeper.joinable()) {
            return;
        }
        stopped = true;
        for (auto & [name, r] : records) {
            take_waiters(lk, r, waiters);
            if (r.backend && (r.status == model_status::loading || r.status == model_status::unloading)) {
                r.backend->cancel_load(); // no-op once loaded; the backend stops below
            }
            if (r.download_cancel) {
                r.download_cancel->store(true);
            }
            if (r.loader.joinable()) {
                loaders.push_back(std::move(r.loader));
            }
        }
        for (auto & weak : subscribers) {
            if (auto sub = weak.lock()) {
                sub->close({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
            }
        }
        subscribers.clear();
        changed.notify_all();
    }
    const event reason {event_type::cancelled, nullptr, "stopped", "Engine stopped"};
    for (auto & w : waiters) {
        w->state->finish(reason);
    }
    if (housekeeper.joinable()) {
        housekeeper.join(); // drains pending unloads first
    }
    for (auto & t : loaders) {
        t.join();
    }
    std::vector<std::shared_ptr<model_backend>> backends;
    std::vector<std::thread> threads;
    {
        lock_t lk(mutex);
        for (auto & job : stops) {
            backends.push_back(std::move(job.backend));
        }
        stops.clear();
        for (auto & [name, r] : records) {
            if (r.backend) {
                backends.push_back(std::move(r.backend));
            }
            if (r.status != model_status::failed) {
                r.status = model_status::unloaded;
            }
            r.active = 0;
        }
        threads = std::move(retired);
        retired.clear();
    }
    for (auto & backend : backends) {
        if (backend) {
            backend->stop(reason);
        }
    }
    for (auto & t : threads) {
        t.join();
    }
}

} } // namespace llama_engine::detail
