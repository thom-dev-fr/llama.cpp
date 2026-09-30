#include "llama-engine.h"
#include "engine-context.h"
#include "engine-runtime.h"
#include "engine-operations.h"
#include "engine-models.h"
#include "engine-options.h"
#include "server-common.h"
#include <algorithm>
#include <filesystem>
#include <limits>

void engine_backend_init() {
    // llama_backend_free currently frees process-wide quantization tables. An
    // instance must not free those while another instance or the server runs.
    // Keep the backend registry/tables for process lifetime, as llama's registry
    // already does; per-model allocations are still released on engine stop.
    static std::once_flag initialized;
    std::call_once(initialized, [] { llama_backend_init(); });
}

namespace llama_engine {
namespace detail {

void request_state::finish(event end) {
    std::function<void()> hook;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (finished) { return; }
        terminal = std::move(end);
        finished = true;
        hook = std::move(on_finish);
        ready.notify_all();
    }
    if (hook) { hook(); }
}

bool request_state::attach_finish_hook(std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(mutex);
    if (finished) { return false; }
    on_finish = std::move(hook);
    return true;
}

bool request_state::attach_cancel(std::function<void()> cancel) {
    std::lock_guard<std::mutex> lock(mutex);
    if (finished) { return false; }
    cancel_work = std::move(cancel);
    return true;
}

void request_state::cancel() {
    std::function<void()> cancel_fn, hook;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (finished) { return; }
        finished = true;
        terminal = {event_type::cancelled, nullptr, "cancelled", "Request cancelled"};
        cancel_fn = cancel_work;
        hook = std::move(on_finish);
        ready.notify_all();
    }
    if (cancel_fn) { cancel_fn(); }
    if (hook) { hook(); }
}

void request_state::push(server_task_result_ptr result) {
    if (fail_on_no_slot) {
        auto * slots = dynamic_cast<server_task_result_slots *>(result.get());
        if (slots && slots->n_idle_slots == 0) {
            auto error = std::make_unique<server_task_result_error>();
            error->err_type = ERROR_TYPE_UNAVAILABLE;
            error->err_msg = "no slot available";
            result = std::move(error);
        }
    }
    std::function<void()> cancel_fn, hook;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (finished) { return; }
        if (result->is_error()) {
            native_error = std::move(result);
            terminal = {event_type::error, nullptr, "inference_error", "Inference failed"};
            finished = true;
            cancel_fn = cancel_work;
        } else if (pending.size() >= capacity) {
            terminal = {event_type::error, nullptr, "queue_full", "Request event queue is full"};
            finished = true;
            cancel_fn = cancel_work;
        } else {
            if (result->is_stop() && --remaining == 0) {
                terminal = {event_type::success, nullptr, {}, {}};
                finished = true;
            }
            pending.push_back(std::move(result));
        }
        if (finished) { hook = std::move(on_finish); }
        ready.notify_all();
    }
    if (cancel_fn) { cancel_fn(); }
    if (hook) { hook(); }
}

native_item request_state::next_native(std::chrono::milliseconds timeout) {
    // caller holds reader_mutex
    server_task_result_ptr result;
    {
        std::unique_lock<std::mutex> lock(mutex);
        const auto available = [&] { return !pending.empty() || finished; };
        if (timeout == std::chrono::milliseconds::max()) {
            ready.wait(lock, available);
        } else if (!ready.wait_for(lock, timeout, available)) {
            return {{event_type::timeout, nullptr, {}, {}}, nullptr};
        }
        if (pending.empty()) {
            if (native_error) {
                terminal.data = json::parse(safe_json_to_str(native_error->to_json()));
                terminal.message = terminal.data.value("message", terminal.message);
                native_error.reset();
            }
            return {terminal, nullptr};
        }
        result = std::move(pending.front());
        pending.pop_front();
    }
    // Conversion runs on the caller, never the decode thread. In particular,
    // the last business payload is delivered before the separate terminal event.
    if (result->index < conversion.size()) { result->update(conversion[result->index]); }
    return {{event_type::payload, nullptr, {}, {}}, std::move(result)};
}

native_item request_state::read_native(std::chrono::milliseconds timeout) {
    std::lock_guard<std::mutex> reader(reader_mutex);
    return next_native(timeout);
}

event request_state::read(std::chrono::milliseconds timeout) {
    std::lock_guard<std::mutex> reader(reader_mutex);
    auto item = next_native(timeout);
    if (!item.result) { return item.status; }
    auto data = json::parse(safe_json_to_str(item.result->to_json()));
    if (!stream && item.result->index < complete.size()) { complete[item.result->index] = data; }
    return {event_type::payload, std::move(data), {}, {}};
}

void runtime::cancel(const std::unordered_set<int> & ids) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!stopped && context) { context->responses().cancel_sinks(ids, context->tasks()); }
}

void apply_http_compat_limits(runtime & run) {
    constexpr size_t unbounded = std::numeric_limits<size_t>::max();
    std::lock_guard<std::mutex> lock(run.mutex);
    run.limits.max_tasks = unbounded;
    run.limits.max_events = unbounded;
    run.limits.max_request_bytes = unbounded;
}

std::unique_ptr<request> submit(const std::shared_ptr<runtime> & run, json input,
                              std::vector<attachment> files, operation op) {
    return std::make_unique<request>(submit_state(run, std::move(input), std::move(files), op));
}

bool prepare_input(const config & limits, request_state & state, const json & input_ref,
                   const std::vector<attachment> & files, operation op, ::json & data) {
    try {
        json input = input_ref;
        const bool size_bounded = limits.max_request_bytes != std::numeric_limits<size_t>::max();
        auto bytes = size_bounded ? input.dump().size() : 0;
        for (const auto & file : files) {
            for (size_t size : {file.name.size(), file.bytes.size()}) {
                if (size > limits.max_request_bytes - std::min(bytes, limits.max_request_bytes)) {
                    throw std::invalid_argument("Request attachments exceed max_request_bytes");
                }
                bytes += size;
            }
        }
        if (bytes > limits.max_request_bytes) { throw std::invalid_argument("Request exceeds max_request_bytes"); }
        if (op <= operation::transcription && !limits.generation_defaults.empty()) {
            if (!input.is_object()) { throw std::invalid_argument("Expected a JSON object"); }
            json merged = limits.generation_defaults;
            merged.update(input);
            input = std::move(merged);
        }
        data = ::json::parse(input.dump());
    } catch (const std::exception & error) {
        state.finish({event_type::error, nullptr, "invalid_request", error.what()});
        return false;
    }
    return true;
}

std::shared_ptr<request_state> submit_state(const std::shared_ptr<runtime> & run, json input,
                                            std::vector<attachment> files, operation op) {
    auto state = std::make_shared<request_state>();
    ::json data;
    if (prepare_input(run->limits, *state, input, files, op, data)) {
        submit_native(run, state, data, op, files);
    }
    return state;
}

void submit_native(const std::shared_ptr<runtime> & run, const std::shared_ptr<request_state> & state,
                   const ::json & data, operation op, const std::vector<attachment> & files) {
    {
        std::lock_guard<std::mutex> lock(run->mutex);
        if (run->stopped || !run->context) {
            state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
            return;
        }
        ++run->preparing; // stop() waits for this before the context can be released
    }
    struct preparation {
        runtime & run;
        ~preparation() {
            std::lock_guard<std::mutex> lock(run.mutex);
            --run.preparing;
            run.prepared.notify_all();
        }
    } preparing {*run};
    try {
        state->capacity = run->limits.max_events;
        state->fail_on_no_slot = op == operation::slots && json_value(data, "fail_on_no_slot", false);
        auto & context = *run->context;
        prepared_operation prepared;
        std::vector<server_task> tasks;
        // Shape and field validation (including non-object input) is left to
        // the task schema, so errors match the server's historical messages.
        // Preparation runs concurrently on the submitting threads, as before.
        struct context_pin {
            server_queue & queue;
            bool held;
            explicit context_pin(server_queue & queue, bool wake) : queue(queue), held(queue.acquire_context(wake)) {}
            ~context_pin() { if (held) { queue.release_context(); } }
        } pin(context.tasks(), op != operation::metrics && op != operation::properties && op != operation::models);
        if (!pin.held && op != operation::metrics && op != operation::properties && op != operation::models) {
            std::string wake_error;
            if (context.tasks().wake_failed(wake_error)) {
                state->finish({event_type::error, nullptr, "wake_failed", wake_error});
            } else {
                state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
            }
            return;
        }
        if (!pin.held && op == operation::metrics) {
            std::lock_guard<std::mutex> lock(run->snapshot_mutex);
            server_task_result_metrics result;
            result.metrics = run->sleep_metrics;
            prepared.immediate = result.to_json();
            if (json_value(data, "reset", true)) {
                run->sleep_metrics.reset_bucket();
                run->reset_metrics_on_wake = true;
            }
        } else {
            prepared = prepare_operation(context, op, data, files, run->limits.max_tasks);
        }
        tasks = std::move(prepared.tasks);
        state->format = prepared.format;
        state->assemble = std::move(prepared.assemble);
        if (!prepared.immediate.is_null()) {
            std::lock_guard<std::mutex> lock(run->mutex);
            if (run->stopped) {
                state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
                return;
            }
            struct immediate_result : server_task_result {
                ::json data;
                ::json to_json() override { return data; }
            };
            auto result = std::make_unique<immediate_result>();
            result->data = std::move(prepared.immediate);
            state->remaining = 1;
            state->complete.resize(1);
            state->push(std::move(result));
            return;
        }
        auto ids = server_task::get_list_id(tasks);
        if (ids.empty()) { throw std::invalid_argument("No prompts supplied"); }
        state->sse_ping_interval = tasks.front().params.sse_ping_interval;
        state->stream = tasks.front().params.stream; // validated by the task schema
        state->remaining = ids.size();
        state->complete.resize(ids.size());
        size_t index = 0;
        for (auto & task : tasks) {
            task.index = index++;
            state->conversion.push_back(task.create_state());
            for (auto & child : task.child_tasks) {
                child.index = index++;
                state->conversion.push_back(child.create_state());
            }
        }
        std::weak_ptr<runtime> weak = run;
        std::lock_guard<std::mutex> lock(run->mutex);
        if (run->stopped) {
            state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
            return;
        }
        // The handle may already be visible to its reader (requests queued for
        // a model load): a cancellation before this point posts nothing, and a
        // later one waits for run->mutex, so it always sees registered sinks.
        if (!state->attach_cancel([weak, ids] { if (auto owner = weak.lock()) { owner->cancel(ids); } })) {
            return;
        }
        if (!context.responses().add_sinks(ids, run->limits.max_tasks,
                [state](server_task_result_ptr result) { state->push(std::move(result)); })) {
            state->finish({event_type::error, nullptr, "capacity_exceeded", "Engine task limit reached"});
            return;
        }
        // Expired handles never cause an unbounded bookkeeping list.
        run->requests.erase(std::remove_if(run->requests.begin(), run->requests.end(),
            [](const std::weak_ptr<request_state> & value) {
                auto state = value.lock();
                if (!state) { return true; }
                std::lock_guard<std::mutex> lock(state->mutex);
                return state->finished;
            }), run->requests.end());
        run->requests.push_back(state);
        context.tasks().post(std::move(tasks), prepared.priority);
    } catch (const operation_error & error) {
        state->finish({event_type::error, json::parse(error.data.dump()), "invalid_request", error.what()});
    } catch (const std::length_error & error) {
        state->finish({event_type::error, nullptr, "capacity_exceeded", error.what()});
    } catch (const std::invalid_argument & error) {
        state->finish({event_type::error, nullptr, "invalid_request", error.what()});
    } catch (const std::exception & error) {
        state->finish({event_type::error, nullptr, "preparation_failed", error.what()});
    }
}

void request_stop(const std::shared_ptr<runtime> & run, const event & reason) {
    {
        std::lock_guard<std::mutex> lock(run->mutex);
        if (!run->stopped) {
            run->stopped = true;
            for (auto & weak : run->requests) {
                if (auto state = weak.lock()) {
                    state->finish(reason);
                }
            }
            if (run->context) { run->context->tasks().terminate(); }
        }
    }
}

void stop(const std::shared_ptr<runtime> & run) {
    request_stop(run);
    {
        // Submitting threads may still be preparing against the context.
        std::unique_lock<std::mutex> lock(run->mutex);
        run->prepared.wait(lock, [&] { return run->preparing == 0; });
    }
    std::lock_guard<std::mutex> join(run->join_mutex);
    if (run->decoder.joinable()) { run->decoder.join(); }
}

bool valid_config(const config & settings, std::string & error) {
    const auto positive = [](const std::optional<int> & v) { return !v || *v > 0; };
    if (!positive(settings.context_size) || !positive(settings.parallel) || !positive(settings.threads) ||
        !positive(settings.batch_size) || !positive(settings.micro_batch_size) || !settings.max_tasks ||
        !settings.max_events || !settings.max_request_bytes || !settings.generation_defaults.is_object() ||
        settings.pooling_type < LLAMA_POOLING_TYPE_UNSPECIFIED || settings.pooling_type > LLAMA_POOLING_TYPE_RANK ||
        settings.sleep_idle_seconds < -1 || settings.sleep_idle_seconds == 0) {
        error = "Invalid engine configuration";
        return false;
    }
    try {
        build_params(settings); // options, their values and a model source
    } catch (const std::exception & e) {
        error = e.what();
        return false;
    }
    return true;
}

struct engine_impl {
    std::mutex shutdown_mutex;
    std::shared_ptr<model_manager> models;
};

std::shared_ptr<model_manager> make_catalog_manager(const catalog_config & settings, backend_factory factory,
                                                    std::function<void(model_entry &)> adjust, event & error) {
    error = {};
    try {
        catalog_config merged = settings;
        if (settings.sources) {
            std::vector<model_entry> read;
            event status = read_catalog(*settings.sources, read);
            if (status.type != event_type::success) {
                error = status;
                return nullptr;
            }
            merged.models = std::move(read);
            merged.models.insert(merged.models.end(), settings.models.begin(), settings.models.end());
        }
        if (adjust) {
            for (auto & m : merged.models) {
                adjust(m);
            }
        }
        std::string message;
        if (!model_manager::validate(merged, message)) {
            error = {event_type::error, nullptr, "invalid_config", message};
            return nullptr;
        }
        auto models = std::make_shared<model_manager>(merged, false, std::move(factory));
        if (settings.sources) {
            models->set_sources(*settings.sources, settings.models);
        }
        models->set_entry_adjust(std::move(adjust));
        models->start();
        return models;
    } catch (const std::exception & ex) {
        error = {event_type::error, nullptr, "invalid_config", ex.what()};
        return nullptr;
    }
}
} // namespace detail

request::request(std::shared_ptr<detail::request_state> state) : state(std::move(state)) {}
request::~request() { cancel(); }
void request::cancel() { state->cancel(); }
event request::next() { return state->read(std::chrono::milliseconds::max()); }
event request::next_for(std::chrono::milliseconds timeout) { return state->read(timeout); }
event request::result() {
    if (state->stream) { throw std::logic_error("Use next() for streaming requests"); }
    for (;;) {
        auto item = next();
        if (item.terminal()) {
            if (item.type == event_type::success) {
                std::lock_guard<std::mutex> reader(state->reader_mutex);
                if (state->complete.empty() && !state->assemble && !item.data.is_null()) {
                    return item; // no payload: the result is the terminal data (downloads)
                }
                if (state->assemble) {
                    item.data = json::parse(safe_json_to_str(state->assemble(::json::parse(json(state->complete).dump()))));
                } else {
                    item.data = state->complete.size() == 1 ? state->complete.front() : json(state->complete);
                }
            }
            return item;
        }
    }
}

subscription::subscription(std::shared_ptr<detail::subscriber_state> state) : state(std::move(state)) {}
subscription::~subscription() { state->close({event_type::cancelled, nullptr, "unsubscribed", "Unsubscribed"}); }
event subscription::next() { return state->read(std::chrono::milliseconds::max()); }
event subscription::next_for(std::chrono::milliseconds timeout) { return state->read(timeout); }

config config::from_options(std::map<std::string, std::string> options) {
    config settings;
    settings.context_size = settings.parallel = settings.threads = std::nullopt;
    settings.gpu_layers = settings.batch_size = settings.micro_batch_size = std::nullopt;
    settings.fit = settings.warmup = std::nullopt;
    settings.options = std::move(options);
    return settings;
}

engine::engine() : impl(new detail::engine_impl) {}
engine::~engine() { stop(); }

std::unique_ptr<engine> engine::create(const config & settings, event & error) {
    error = {};
    try {
        std::string message;
        if (!detail::valid_config(settings, message)) {
            error = {event_type::error, nullptr, "invalid_config", message};
            return nullptr;
        }
        // One catalog entry, loaded now; its model field is not used for selection.
        catalog_config catalog;
        model_entry entry;
        entry.id       = model_id(settings);
        entry.settings = settings;
        catalog.models.push_back(std::move(entry));
        catalog.max_loaded  = 1;
        catalog.max_waiting = std::max<size_t>(settings.max_tasks, 1);
        if (!detail::model_manager::validate(catalog, message)) {
            error = {event_type::error, nullptr, "invalid_config", message};
            return nullptr;
        }
        auto owner = std::unique_ptr<engine>(new engine);
        owner->impl->models = std::make_shared<detail::model_manager>(catalog, true, detail::make_context_backend);
        owner->impl->models->start();
        auto loaded = owner->impl->models->load(catalog.models.front().id)->read(std::chrono::milliseconds::max());
        if (loaded.type != event_type::success) {
            error = loaded.category == "load_failed"
                ? event {event_type::error, nullptr, "load_failed", "Failed to load model: " + model_id(settings)}
                : loaded;
            return nullptr;
        }
        return owner;
    } catch (const std::exception & ex) {
        error = {event_type::error, nullptr, "load_failed", ex.what()};
        return nullptr;
    }
}

std::unique_ptr<engine> engine::create_catalog(const catalog_config & settings, event & error) {
    auto models = detail::make_catalog_manager(settings, detail::make_context_backend, nullptr, error);
    if (!models) {
        return nullptr;
    }
    auto owner = std::unique_ptr<engine>(new engine);
    owner->impl->models = std::move(models);
    return owner;
}

std::unique_ptr<request> engine::submit(operation op, json input, std::vector<attachment> files) {
    return std::make_unique<request>(impl->models->submit(op, input, std::move(files)));
}
std::unique_ptr<request> engine::completion(json input, std::vector<attachment> files) {
    return submit(operation::completion, std::move(input), std::move(files));
}
json engine::catalog() const { return impl->models->catalog(); }
std::unique_ptr<subscription> engine::subscribe() { return std::make_unique<subscription>(impl->models->subscribe()); }
std::unique_ptr<request> engine::load(const std::string & model) {
    return std::make_unique<request>(impl->models->load(model));
}
event engine::unload(const std::string & model) { return impl->models->unload(model); }
event engine::update_catalog(std::vector<model_entry> models) { return impl->models->update(std::move(models)); }
event engine::reload() { return impl->models->reload(); }
std::unique_ptr<request> engine::download(const std::string & repo, std::map<std::string, std::string> options) {
    return std::make_unique<request>(impl->models->download(repo, options));
}
event engine::remove(const std::string & model) { return impl->models->remove(model); }
void engine::stop() {
    std::lock_guard<std::mutex> lock(impl->shutdown_mutex);
    if (impl->models) { impl->models->stop(); }
}
} // namespace llama_engine
