#include "llama-engine.h"
#include "engine-context.h"
#include "engine-runtime.h"
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

event request_state::read(std::chrono::milliseconds timeout) {
    std::lock_guard<std::mutex> reader(reader_mutex);
    server_task_result_ptr result;
    {
        std::unique_lock<std::mutex> lock(mutex);
        const auto available = [&] { return !pending.empty() || finished; };
        if (timeout == std::chrono::milliseconds::max()) {
            ready.wait(lock, available);
        } else if (!ready.wait_for(lock, timeout, available)) {
            return {event_type::timeout, nullptr, {}, {}};
        }
        if (pending.empty()) {
            if (native_error) {
                terminal.data = json::parse(safe_json_to_str(native_error->to_json()));
                terminal.message = terminal.data.value("message", terminal.message);
                native_error.reset();
            }
            return terminal;
        }
        result = std::move(pending.front());
        pending.pop_front();
    }
    // Conversion runs on the caller, never the decode thread. In particular,
    // the last business payload is delivered before the separate terminal event.
    if (result->index < conversion.size()) { result->update(conversion[result->index]); }
    auto data = json::parse(safe_json_to_str(result->to_json()));
    if (!stream && result->index < complete.size()) { complete[result->index] = data; }
    return {event_type::payload, std::move(data), {}, {}};
}

void runtime::cancel(const std::unordered_set<int> & ids) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!stopped && context) { context->responses().cancel_sinks(ids, context->tasks()); }
}

std::unique_ptr<request> submit(const std::shared_ptr<runtime> & run, json input,
                              std::vector<attachment> files) {
    auto state = std::make_shared<request_state>();
    auto handle = std::make_unique<request>(state);
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->stopped || !run->context) {
        state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
        return handle;
    }
    try {
        if (!input.is_object()) { throw std::invalid_argument("Expected a JSON object"); }
        auto bytes = input.dump().size();
        for (const auto & file : files) {
            if (file.bytes.size() > run->limits.max_request_bytes - std::min(bytes, run->limits.max_request_bytes)) {
                throw std::invalid_argument("Request attachments exceed max_request_bytes");
            }
            bytes += file.bytes.size();
        }
        if (bytes > run->limits.max_request_bytes) { throw std::invalid_argument("Request exceeds max_request_bytes"); }
        json merged = run->limits.generation_defaults;
        merged.update(input);
        state->stream = merged.value("stream", false);
        state->capacity = run->limits.max_events;
        // Binary buffers are owned by this invocation throughout preparation.
        // Native completions embed media in their existing JSON schema; named
        // attachments are reserved for the operations migrated in P3.
        if (!files.empty()) { throw std::invalid_argument("Native completion uses multimodal_data; named attachments are not supported by this operation"); }
        auto & context = *run->context;
        struct context_pin {
            server_queue & queue;
            bool held;
            explicit context_pin(server_queue & queue) : queue(queue), held(queue.acquire_context()) {}
            ~context_pin() { if (held) { queue.release_context(); } }
        } pin(context.tasks());
        if (!pin.held) {
            state->finish({event_type::cancelled, nullptr, "stopped", "Engine stopped"});
            return handle;
        }
        auto tasks = context.prepare_completion(::json::parse(merged.dump()), SERVER_TASK_TYPE_COMPLETION,
                                                TASK_RESPONSE_TYPE_NONE, {}, run->limits.max_tasks);
        auto ids = server_task::get_list_id(tasks);
        if (ids.empty()) { throw std::invalid_argument("No prompts supplied"); }
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
        if (!context.responses().add_sinks(ids, run->limits.max_tasks,
                [state](server_task_result_ptr result) { state->push(std::move(result)); })) {
            state->finish({event_type::error, nullptr, "capacity_exceeded", "Engine task limit reached"});
            return handle;
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
        context.tasks().post(std::move(tasks));
    } catch (const std::length_error & error) {
        state->finish({event_type::error, nullptr, "capacity_exceeded", error.what()});
    } catch (const std::exception & error) {
        state->finish({event_type::error, nullptr, "invalid_request", error.what()});
    }
    return handle;
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
                item.data = state->complete.size() == 1 ? state->complete.front() : json(state->complete);
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
            !settings.generation_defaults.is_object()) {
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
std::unique_ptr<request> engine::completion(json input, std::vector<attachment> files) {
    return detail::submit(impl->run, std::move(input), std::move(files));
}
void engine::stop() {
    std::lock_guard<std::mutex> lock(impl->shutdown_mutex);
    detail::stop(impl->run);
    impl->context.reset();
}
} // namespace llama_engine
