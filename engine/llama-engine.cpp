#include "llama-engine.h"
#include "engine-context.h"
#include "engine-runtime.h"
#include "engine-operations.h"
#include "server-common.h"
#include <algorithm>
#include <limits>

void engine_backend_init() {
    // llama_backend_free currently frees process-wide quantization tables. An
    // instance must not free those while another instance/legacy consumer runs.
    // Keep the backend registry/tables for process lifetime, as llama's registry
    // already does; per-model allocations are still released on engine stop.
    static std::once_flag initialized;
    std::call_once(initialized, [] { llama_backend_init(); });
}

namespace llama_engine {
namespace detail {

void request_state::finish(event end) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!finished) {
        terminal = std::move(end);
        finished = true;
        ready.notify_all();
    }
}

void request_state::cancel() {
    std::function<void()> cancel_fn;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (finished) { return; }
        finished = true;
        terminal = {event_type::cancelled, nullptr, "cancelled", "Request cancelled"};
        cancel_fn = cancel_work;
        ready.notify_all();
    }
    if (cancel_fn) { cancel_fn(); }
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
    std::function<void()> cancel_fn;
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
        ready.notify_all();
    }
    if (cancel_fn) { cancel_fn(); }
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

std::shared_ptr<request_state> submit_state(const std::shared_ptr<runtime> & run, json input,
                                            std::vector<attachment> files, operation op) {
    auto state = std::make_shared<request_state>();
    ::json data;
    try {
        const bool size_bounded = run->limits.max_request_bytes != std::numeric_limits<size_t>::max();
        auto bytes = size_bounded ? input.dump().size() : 0;
        for (const auto & file : files) {
            for (size_t size : {file.name.size(), file.bytes.size()}) {
                if (size > run->limits.max_request_bytes - std::min(bytes, run->limits.max_request_bytes)) {
                    throw std::invalid_argument("Request attachments exceed max_request_bytes");
                }
                bytes += size;
            }
        }
        if (bytes > run->limits.max_request_bytes) { throw std::invalid_argument("Request exceeds max_request_bytes"); }
        if (op <= operation::transcription && !run->limits.generation_defaults.empty()) {
            if (!input.is_object()) { throw std::invalid_argument("Expected a JSON object"); }
            json merged = run->limits.generation_defaults;
            merged.update(input);
            input = std::move(merged);
        }
        data = ::json::parse(input.dump());
    } catch (const std::exception & error) {
        state->finish({event_type::error, nullptr, "invalid_request", error.what()});
        return state;
    }
    submit_native(run, state, data, op, files);
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
            state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
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
        state->cancel_work = [weak, ids] { if (auto owner = weak.lock()) { owner->cancel(ids); } };

        std::lock_guard<std::mutex> lock(run->mutex);
        if (run->stopped) {
            state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
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

void request_stop(const std::shared_ptr<runtime> & run) {
    {
        std::lock_guard<std::mutex> lock(run->mutex);
        if (!run->stopped) {
            run->stopped = true;
            for (auto & weak : run->requests) {
                if (auto state = weak.lock()) {
                    state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
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

struct engine_impl {
    std::mutex shutdown_mutex;
    std::unique_ptr<server_context> context {new server_context};
    std::shared_ptr<runtime> run = context->runtime;
};
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

engine::engine() : impl(new detail::engine_impl) {}
engine::~engine() { stop(); }
std::unique_ptr<engine> engine::create(const config & settings, event & error) {
    error = {};
    try {
        if (settings.model_path.empty() || settings.context_size <= 0 || settings.parallel <= 0 ||
            settings.threads <= 0 || settings.batch_size <= 0 || settings.micro_batch_size <= 0 ||
            !settings.max_tasks || !settings.max_events || !settings.max_request_bytes ||
            !settings.generation_defaults.is_object() || settings.pooling_type < LLAMA_POOLING_TYPE_UNSPECIFIED ||
            settings.pooling_type > LLAMA_POOLING_TYPE_RANK) {
            error = {event_type::error, nullptr, "invalid_config", "Invalid engine configuration"};
            return nullptr;
        }
        auto owner = std::unique_ptr<engine>(new engine);
        owner->impl->run->limits = settings;
        common_params params;
        params.model.path = settings.model_path;
        params.n_ctx = settings.context_size;
        params.n_parallel = settings.parallel;
        params.cpuparams.n_threads = settings.threads;
        params.cpuparams_batch.n_threads = settings.threads;
        params.n_gpu_layers = settings.gpu_layers;
        params.n_batch = settings.batch_size;
        params.n_ubatch = settings.micro_batch_size;
        params.chat_template = settings.chat_template;
        params.mmproj.path = settings.mmproj_path;
        params.mmproj_use_gpu = settings.gpu_layers != 0;
        params.embedding = settings.embeddings;
        params.pooling_type = static_cast<enum llama_pooling_type>(settings.pooling_type);
        params.slot_save_path = settings.slot_save_path;
        if (!params.slot_save_path.empty() && params.slot_save_path.back() != DIRECTORY_SEPARATOR) {
            params.slot_save_path += DIRECTORY_SEPARATOR;
        }
        for (const auto & path : settings.lora_paths) { params.lora_adapters.push_back({path, 1.0f, {}, {}, nullptr}); }
        params.fit_params = false;
        params.warmup = false;
        params.sleep_idle_seconds = -1;
        if (!owner->impl->context->load_model(params)) {
            error = {event_type::error, nullptr, "load_failed", "Failed to load model: " + settings.model_path};
            return nullptr;
        }
        owner->impl->context->start();
        return owner;
    } catch (const std::exception & ex) {
        error = {event_type::error, nullptr, "load_failed", ex.what()};
        return nullptr;
    }
}
std::unique_ptr<request> engine::submit(operation op, json input, std::vector<attachment> files) {
    return detail::submit(impl->run, std::move(input), std::move(files), op);
}
std::unique_ptr<request> engine::completion(json input, std::vector<attachment> files) {
    return detail::submit(impl->run, std::move(input), std::move(files));
}
void engine::stop() {
    std::lock_guard<std::mutex> lock(impl->shutdown_mutex);
    detail::stop(impl->run);
    impl->context.reset();
}
} // namespace llama_engine
