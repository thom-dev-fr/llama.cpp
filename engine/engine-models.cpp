#include "engine-models.h"
#include "engine-context.h"
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
        common_params params = to_common_params(entry.settings);
        if (!context->load_model(params)) {
            error = "Failed to load model: " + entry.settings.model_path;
            return false;
        }
        context->start();
        return true;
    }

    void cancel_load() override { context->cancel_load(); }

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
    if (settings.models.empty() || settings.max_waiting == 0 || settings.max_subscriber_events == 0 ||
        settings.wait_timeout <= std::chrono::milliseconds::zero()) {
        error = "Invalid catalog configuration";
        return false;
    }
    std::set<std::string> names;
    for (const auto & entry : settings.models) {
        if (entry.id.empty() || !valid_config(entry.settings)) {
            error = "Invalid configuration for model '" + entry.id + "'";
            return false;
        }
        if (!names.insert(entry.id).second) {
            error = "Duplicate model name '" + entry.id + "'";
            return false;
        }
    }
    for (const auto & entry : settings.models) {
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
    record * r = resolve(name);
    if (!r) {
        state->finish({event_type::error, nullptr, "model_not_found", "model '" + name + "' not found"});
        return state;
    }
    ::json data;
    if (!prepare_input(r->entry.settings, *state, input, files, op, data)) {
        return state;
    }
    lock_t lk(mutex);
    if (stopped) {
        lk.unlock();
        state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return state;
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
    if (!settings.autoload && r->status != model_status::loading) {
        lk.unlock();
        state->finish({event_type::error, nullptr, "model_not_loaded", "model is not loaded"});
        return state;
    }
    return enqueue(lk, *r, state, std::move(data), op, std::move(files), false);
}

std::shared_ptr<request_state> model_manager::load(const std::string & model) {
    auto state = std::make_shared<request_state>();
    record * r = resolve(model);
    if (!r || (single && !model.empty() && model != r->entry.id && !r->aliases.count(model))) {
        state->finish({event_type::error, nullptr, "model_not_found", "model '" + model + "' not found"});
        return state;
    }
    lock_t lk(mutex);
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
    r.generation++;
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
    r.backend = factory(r.entry, std::move(hooks));
    if (r.loader.joinable()) {
        retired.push_back(std::move(r.loader));
    }
    r.loader = std::thread([this, name = r.entry.id, generation = r.generation, backend = r.backend] {
        run_load(name, generation, backend);
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

void model_manager::run_load(const std::string & name, uint64_t generation, std::shared_ptr<model_backend> backend) {
    std::string error;
    bool ok = false;
    try {
        ok = backend->load(error);
    } catch (const std::exception & e) {
        error = e.what();
    }
    if (!ok) {
        backend->stop({event_type::cancelled, nullptr, "stopped", "Engine stopped"}); // partial resources
    }
    std::vector<std::shared_ptr<waiter>> waiters;
    std::vector<std::shared_ptr<waiter>> admitted;
    std::shared_ptr<model_backend> resident;
    event failure;
    {
        lock_t lk(mutex);
        record & r = records.at(name);
        if (r.loader.joinable() && r.loader.get_id() == std::this_thread::get_id()) {
            retired.push_back(std::move(r.loader)); // joined by the housekeeper or stop()
            changed.notify_all();
        }
        if (stopped || r.generation != generation) {
            return; // stop() frees the backend after joining this thread
        }
        if (r.unload_requested) {
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
            failure  = {event_type::error, nullptr, "load_failed", r.error};
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
    record * r = resolve(model);
    if (!r || (single && !model.empty() && model != r->entry.id && !r->aliases.count(model))) {
        return {event_type::error, nullptr, "model_not_found", "model '" + model + "' not found"};
    }
    std::vector<std::shared_ptr<waiter>> waiters;
    lock_t lk(mutex);
    if (stopped) {
        return {event_type::cancelled, nullptr, "stopped", "Engine stopped"};
    }
    const event reason {event_type::cancelled, nullptr, "unloaded", "Model unloaded"};
    switch (r->status) {
        case model_status::unloaded:
        case model_status::failed:
            return {event_type::error, nullptr, "model_not_loaded", "model is not loaded"};
        case model_status::unloading:
            break; // already in progress, wait for it below
        case model_status::loading:
            // admissions close now; the load stops at its next progress report
            r->unload_requested = true;
            r->status = model_status::unloading;
            r->backend->cancel_load();
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
    schedule(lk);
    lk.unlock();
    for (auto & w : waiters) {
        w->state->finish(reason);
    }
    lk.lock();
    changed.wait(lk, [&] {
        return stopped || r->generation != generation ||
               (r->status != model_status::unloading && r->status != model_status::loading);
    });
    return {event_type::success, nullptr, {}, {}};
}

void model_manager::drop_waiter(const std::shared_ptr<waiter> & w) {
    lock_t lk(mutex);
    record & r = records.at(w->model);
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
    record & r = records.at(name);
    if (r.generation != generation || r.active == 0) {
        return;
    }
    r.active--;
    r.last_used = ggml_time_ms();
    if (r.active == 0) {
        schedule(lk); // an idle model can now make room for a queued one
        changed.notify_all();
    }
}

void model_manager::on_progress(const std::string & name, uint64_t generation, const ::json & progress) {
    lock_t lk(mutex);
    record & r = records.at(name);
    if (r.generation != generation || stopped) {
        return;
    }
    r.progress = json::parse(progress.dump());
    publish({{"type", "progress"}, {"model", name}, {"progress", r.progress}});
}

void model_manager::on_sleep(const std::string & name, uint64_t generation, bool sleeping) {
    lock_t lk(mutex);
    record & r = records.at(name);
    if (r.generation != generation || stopped) {
        return;
    }
    if (r.status == model_status::loading) {
        r.asleep = sleeping;
    } else if (r.status == model_status::loaded || r.status == model_status::sleeping) {
        r.status = sleeping ? model_status::sleeping : model_status::loaded;
        publish_status(r);
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
    if (!r.progress.is_null() && r.status == model_status::loading) {
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
        out.push_back(describe(r));
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
            record & r = records.at(job.model);
            if (r.generation == job.generation && r.status == model_status::unloading) {
                r.status   = model_status::unloaded;
                r.progress = nullptr;
                publish_status(r);
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
