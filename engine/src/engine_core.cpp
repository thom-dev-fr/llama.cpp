#include "engine_core.hpp"

#include "params_translator.hpp"

#include "common.h"
#include "log.h"
#include "llama.h"
#include "ggml-backend.h"

#include <algorithm>
#include <functional>
#include <stdexcept>
#include <utility>

namespace llama_engine {

std::once_flag   engine_core::backend_once;
std::atomic<int> engine_core::log_verbosity{2}; // default: warnings + errors

void engine_core::set_log_verbosity(int level) {
    log_verbosity.store(level);
    common_log_set_verbosity_thold(level);
    llama_log_set([](ggml_log_level level, const char * text, void * /*user_data*/) {
        // Route everything through common_log so common_log_set_verbosity_thold
        // controls filtering uniformly.
        common_log_add(common_log_main(), level, "%s", text);
    }, nullptr);
}

void engine_core::ensure_backend_initialized() {
    std::call_once(backend_once, []() {
        set_log_verbosity(log_verbosity.load());
        ggml_backend_load_all();
        llama_backend_init();
    });
}

engine_core::~engine_core() {
    std::unique_lock<std::mutex> lock(mtx);
    if (lifecycle.state() != LLAMA_ENGINE_STATE_UNLOADED) {
        teardown_locked(lock);
    }
}

void engine_core::set_error(std::string msg) {
    last_error_ = std::move(msg);
}

llama_engine_state engine_core::state() const {
    return lifecycle.state();
}

bool engine_core::is_mtp_active() const {
    std::lock_guard<std::mutex> lock(mtx);
    if (!last_params.has_value()) return false;
    const auto & types = last_params->speculative.types;
    return std::find(types.begin(), types.end(),
                     COMMON_SPECULATIVE_TYPE_DRAFT_MTP) != types.end();
}

const char * engine_core::last_error() {
    std::lock_guard<std::mutex> lock(mtx);
    return last_error_.empty() ? nullptr : last_error_.c_str();
}

llama_engine_status engine_core::load(const llama_engine_config & cfg) {
    std::unique_lock<std::mutex> lock(mtx);
    return load_locked(cfg, lock);
}

llama_engine_status engine_core::load_locked(const llama_engine_config & cfg,
                                             std::unique_lock<std::mutex> & lock)
{
    if (!lifecycle.can_start_load()) {
        set_error("engine already loaded or busy");
        return LLAMA_ENGINE_ERR_ALREADY_LOADED;
    }

    try {
        last_params = params_translator::translate(cfg);
    } catch (const std::exception & e) {
        set_error(std::string("invalid config: ") + e.what());
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }

    return load_from_params_locked(lock, /*from_resume=*/false);
}

llama_engine_status engine_core::load_from_params_locked(std::unique_lock<std::mutex> & lock,
                                                         bool from_resume)
{
    if (!last_params.has_value()) {
        set_error("no cached params for load_from_params");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    lifecycle.enter_loading(from_resume);
    last_error_.clear();

    ensure_backend_initialized();

    // Wire the load-progress callback through Engine Lifecycle's progress
    // hook. The void* points at the lifecycle, so Engine Core never
    // participates in the cancellation read.
    auto hook = lifecycle.progress_hook();
    last_params->load_progress_callback           = hook.callback;
    last_params->load_progress_callback_user_data = hook.user_data;

    auto new_ctx = std::make_unique<server_context>();

    // Drop the lock during load_model(); it synchronously initialises the
    // model and can take seconds. Only pause() is allowed to alter Engine
    // Lifecycle while we are here: it posts load preemption and waits on
    // the lifecycle CV (via wait_until_pause_resolved).
    lock.unlock();

    bool load_ok = false;
    std::string err;
    try {
        load_ok = new_ctx->load_model(*last_params);
    } catch (const std::exception & e) {
        err = e.what();
    } catch (...) {
        err = "unknown exception while loading model";
    }

    lock.lock();

    const bool pause_won = lifecycle.consume_pause_preemption();
    lifecycle.clear_load_preemption();

    if (!load_ok) {
        if (pause_won) {
            // Load was aborted because pause() asked us to. Transition to
            // PAUSED and keep last_params so a later resume() can retry.
            set_error("load cancelled by pause()");
            lifecycle.cancel_to_paused();
            return LLAMA_ENGINE_ERR_CANCELLED;
        }
        set_error(err.empty() ? "failed to load model" : err);
        lifecycle.fail_load();
        return LLAMA_ENGINE_ERR_LOAD_FAILED;
    }

    // Load succeeded — wire the runtime.
    ctx    = std::move(new_ctx);
    meta   = std::make_unique<server_context_meta>(ctx->get_meta());
    vocab  = llama_model_get_vocab(llama_get_model(ctx->get_llama_context()));
    routes = std::make_shared<server_routes>(*last_params, *ctx);
    routes->update_meta(*ctx);

    // pause() may have arrived during the gap between load_model() returning
    // success and loop_thread spawning. If so, tear down what we just wired.
    // This must happen BEFORE loop_thread is created: server_queue::start_loop
    // unconditionally sets `running = true` at entry, so a terminate() raised
    // before the thread actually runs would be silently overwritten and the
    // join() in teardown_locked() would hang forever.
    if (pause_won) {
        lifecycle.enter_pausing();
        teardown_locked(lock);
        set_error("load preempted by pause()");
        lifecycle.enter_paused();
        return LLAMA_ENGINE_ERR_CANCELLED;
    }

    loop_thread = std::thread([this]() {
        ctx->start_loop();
    });

    lifecycle.complete_load_success();
    return LLAMA_ENGINE_OK;
}

void engine_core::teardown_locked(std::unique_lock<std::mutex> & lock) {
    // Drain in-flight chat work before destroying ctx/routes. The drain
    // releases the registry's own mutex during the bounded wait; we drop
    // ours too because preempt callbacks acquire per-stream mutexes.
    lock.unlock();
    registry.preempt_all_and_drain([](stream_handle * s) {
        chat_route_adapter::stream_preempt(s);
    });
    lock.lock();

    if (ctx) {
        ctx->terminate();
        lock.unlock();
        if (loop_thread.joinable()) {
            loop_thread.join();
        }
        lock.lock();
        routes.reset();
        meta.reset();
        ctx.reset();
        vocab = nullptr;
    }
}

llama_engine_status engine_core::unload() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = lifecycle.state();
    if (s == LLAMA_ENGINE_STATE_UNLOADED) {
        return LLAMA_ENGINE_OK;
    }
    if (s == LLAMA_ENGINE_STATE_LOADING || s == LLAMA_ENGINE_STATE_UNLOADING ||
        s == LLAMA_ENGINE_STATE_PAUSING || s == LLAMA_ENGINE_STATE_RESUMING) {
        set_error("engine is busy");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    lifecycle.enter_unloading();
    teardown_locked(lock);
    last_params.reset();
    lifecycle.enter_unloaded();
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::pause() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = lifecycle.state();

    if (s == LLAMA_ENGINE_STATE_PAUSED) {
        return LLAMA_ENGINE_OK;
    }

    if (s == LLAMA_ENGINE_STATE_PAUSING) {
        // Another pause() is already tearing down. Wait for it to finish.
        lifecycle.wait_until_pause_resolved(lock);
        return LLAMA_ENGINE_OK;
    }

    if (s == LLAMA_ENGINE_STATE_LOADING || s == LLAMA_ENGINE_STATE_RESUMING) {
        // Preempt an in-flight load (initial load or resume()). Signal the
        // progress callback to abort and wait until the loading thread
        // flips state to a terminal value.
        lifecycle.request_pause_preemption();
        lifecycle.wait_until_pause_resolved(lock);
        auto resolved = lifecycle.state();
        if (resolved == LLAMA_ENGINE_STATE_PAUSED) {
            return LLAMA_ENGINE_OK;
        }
        if (resolved == LLAMA_ENGINE_STATE_READY) {
            // Extremely narrow race: the load finished on a progress-poll
            // boundary before our cancel flag could be observed and the
            // post-load pause_requested check also missed it. Fall through
            // to the READY branch below with the lock still held.
            s = resolved;
        } else {
            set_error("pause() preempted a load that then failed");
            return LLAMA_ENGINE_ERR_NOT_LOADED;
        }
    }

    if (s != LLAMA_ENGINE_STATE_READY) {
        set_error("pause() requires READY, LOADING, RESUMING, PAUSING or PAUSED state");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }

    lifecycle.enter_pausing();
    teardown_locked(lock);
    // last_params intentionally retained for resume().
    lifecycle.enter_paused();
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::resume() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = lifecycle.state();
    if (s == LLAMA_ENGINE_STATE_READY) {
        return LLAMA_ENGINE_OK;
    }
    if (s != LLAMA_ENGINE_STATE_PAUSED) {
        set_error("resume() requires PAUSED state");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }
    return load_from_params_locked(lock, /*from_resume=*/true);
}

llama_engine_status engine_core::tokenize(const std::string & text, bool add_special,
                                          std::vector<int32_t> & out)
{
    std::unique_lock<std::mutex> lock(mtx);
    if (lifecycle.state() != LLAMA_ENGINE_STATE_READY) {
        if (lifecycle.state() == LLAMA_ENGINE_STATE_PAUSED) {
            auto st = load_from_params_locked(lock, /*from_resume=*/true);
            if (st != LLAMA_ENGINE_OK) return st;
        } else {
            set_error("engine not loaded");
            return LLAMA_ENGINE_ERR_NOT_LOADED;
        }
    }
    try {
        auto tokens = common_tokenize(vocab, text, add_special, /*parse_special=*/true);
        out.assign(tokens.begin(), tokens.end());
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::detokenize(const std::vector<int32_t> & tokens,
                                            std::string & out)
{
    std::unique_lock<std::mutex> lock(mtx);
    if (lifecycle.state() != LLAMA_ENGINE_STATE_READY) {
        if (lifecycle.state() == LLAMA_ENGINE_STATE_PAUSED) {
            auto st = load_from_params_locked(lock, /*from_resume=*/true);
            if (st != LLAMA_ENGINE_OK) return st;
        } else {
            set_error("engine not loaded");
            return LLAMA_ENGINE_ERR_NOT_LOADED;
        }
    }
    try {
        std::vector<llama_token> toks(tokens.begin(), tokens.end());
        out = common_detokenize(vocab, toks, /*special=*/true);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::admit_request_locked(std::unique_lock<std::mutex> & lock,
                                                       active_request & req,
                                                       admitted_request & out)
{
    if (lifecycle.state() == LLAMA_ENGINE_STATE_PAUSED) {
        auto st = load_from_params_locked(lock, /*from_resume=*/true);
        if (st != LLAMA_ENGINE_OK) return st;
    }
    if (lifecycle.state() != LLAMA_ENGINE_STATE_READY || !routes) {
        set_error("engine not loaded");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }

    out.routes = routes;
    out.guard = registry.track_request(&req);
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::admit_stream_locked(std::unique_lock<std::mutex> & lock,
                                                     const std::string & request_json,
                                                     admitted_stream & out)
{
    if (lifecycle.state() == LLAMA_ENGINE_STATE_PAUSED) {
        auto st = load_from_params_locked(lock, /*from_resume=*/true);
        if (st != LLAMA_ENGINE_OK) return st;
    }
    if (lifecycle.state() != LLAMA_ENGINE_STATE_READY || !routes) {
        set_error("engine not loaded");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }

    auto handle = chat_route_adapter::make_stream_handle(request_json);
    if (!handle) {
        set_error("failed to allocate stream handle");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    out.routes = routes;
    registry.add_stream(handle.get());
    out.handle = std::move(handle);
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::chat_completion(const std::string & request_json,
                                                 std::string & out_json)
{
    out_json.clear();

    active_request req_state;
    admitted_request admission;

    {
        std::unique_lock<std::mutex> lock(mtx);
        auto st = admit_request_locked(lock, req_state, admission);
        if (st != LLAMA_ENGINE_OK) return st;
    }

    return chat_route_adapter::chat_completion(
        admission.routes,
        request_json,
        req_state,
        out_json,
        [this](std::string msg) { set_error(std::move(msg)); });
}

llama_engine_status engine_core::count_chat_tokens(const std::string & request_json,
                                                   std::string & out_json)
{
    out_json.clear();

    active_request req_state;
    admitted_request admission;

    {
        std::unique_lock<std::mutex> lock(mtx);
        auto st = admit_request_locked(lock, req_state, admission);
        if (st != LLAMA_ENGINE_OK) return st;
    }

    return chat_route_adapter::count_chat_tokens(
        admission.routes,
        request_json,
        req_state,
        out_json,
        [this](std::string msg) { set_error(std::move(msg)); });
}

llama_engine_status engine_core::chat_completion_stream(const std::string & request_json,
                                                        stream_handle ** out_stream)
{
    *out_stream = nullptr;

    admitted_stream admission;
    {
        std::unique_lock<std::mutex> lock(mtx);
        auto st = admit_stream_locked(lock, request_json, admission);
        if (st != LLAMA_ENGINE_OK) return st;
    }

    return chat_route_adapter::open_registered_stream(
        admission.routes,
        registry,
        std::move(admission.handle),
        out_stream,
        [this](std::string msg) { set_error(std::move(msg)); });
}

llama_engine_status engine_core::stream_next(stream_handle * s,
                                             std::string & out_chunk, bool & out_done)
{
    return chat_route_adapter::stream_next(
        s,
        out_chunk,
        out_done,
        [this](std::string msg) { set_error(std::move(msg)); });
}

void engine_core::stream_cancel(stream_handle * s) {
    chat_route_adapter::stream_cancel(s);
}

void engine_core::stream_close(stream_handle * s) {
    if (s == nullptr) return;
    // Unregister from the Inflight Registry first so a concurrent
    // preempt_all_and_drain() can observe the count drop.
    registry.remove_stream(s);
    chat_route_adapter::stream_close(s);
}

} // namespace llama_engine
