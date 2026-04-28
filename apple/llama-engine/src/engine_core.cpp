#include "engine_core.hpp"

#include "params_translator.hpp"
#include "task_builder.hpp"
#include "result_formatter.hpp"

#include "common.h"
#include "log.h"
#include "llama.h"
#include "ggml-backend.h"

#include <chrono>
#include <stdexcept>
#include <utility>

namespace llama_engine {

std::once_flag   engine_core::backend_once;
std::atomic<int> engine_core::log_verbosity{2}; // default: warnings + errors

static void set_log_verbosity(int level) {
    common_log_set_verbosity_thold(level);
    llama_log_set([](ggml_log_level level, const char * text, void * /*user_data*/) {
        // Route everything through common_log so common_log_set_verbosity_thold
        // controls filtering uniformly.
        common_log_add(common_log_main(), level, "%s", text);
    }, nullptr);
}

engine_core::engine_core() {
    std::call_once(backend_once, []() {
        ggml_backend_load_all();
        llama_backend_init();
        set_log_verbosity(log_verbosity.load());
    });
}

engine_core::~engine_core() {
    std::unique_lock<std::mutex> lock(mtx);
    if (state_.load() != LLAMA_ENGINE_STATE_UNLOADED) {
        teardown_locked(lock);
    }
}

void engine_core::set_error(std::string msg) {
    last_error_ = std::move(msg);
}

llama_engine_state engine_core::state() const {
    return state_.load();
}

llama_engine_status engine_core::capabilities(llama_engine_capabilities & out) {
    std::lock_guard<std::mutex> lock(mtx);
    if (!cached_caps.has_value()) {
        set_error("no loaded model");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }
    out = *cached_caps;
    return LLAMA_ENGINE_OK;
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
    if (state_.load() != LLAMA_ENGINE_STATE_UNLOADED &&
        state_.load() != LLAMA_ENGINE_STATE_PAUSED) {
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

    // Reset the cancel flag so a previous preemption doesn't bleed into this
    // load. pause_requested_ is intentionally NOT reset here: pause() may
    // have posted it before we took the lock (the caller holds it on entry)
    // and we want to honour that intent.
    cancel_load_.store(false);

    state_.store(from_resume ? LLAMA_ENGINE_STATE_RESUMING
                             : LLAMA_ENGINE_STATE_LOADING);
    cv_lifecycle.notify_all();
    last_error_.clear();

    // Install the progress callback used to preempt a long-running load.
    // llama_model_load_from_file invokes it every ~1% of loaded tensor data;
    // returning false aborts the load cleanly and causes server_context::
    // load_model() to return false.
    last_params->load_progress_callback = [](float /*progress*/, void * ud) -> bool {
        auto * self = static_cast<engine_core *>(ud);
        return !self->cancel_load_.load();
    };
    last_params->load_progress_callback_user_data = this;

    auto new_ctx = std::make_unique<server_context>();

    // Drop the lock during load_model(); it synchronously initialises the
    // model and can take seconds. Only pause() is allowed to touch state_
    // while we are here (it raises cancel_load_ + pause_requested_ and waits
    // on cv_lifecycle).
    lock.unlock();

    bool ok = false;
    std::string err;
    try {
        ok = new_ctx->load_model(*last_params);
    } catch (const std::exception & e) {
        err = e.what();
    } catch (...) {
        err = "unknown exception while loading model";
    }

    lock.lock();

    const bool was_preempted_by_pause = pause_requested_.exchange(false);
    cancel_load_.store(false);

    if (!ok) {
        if (was_preempted_by_pause) {
            // Load was aborted because pause() asked us to. Transition to
            // PAUSED and keep last_params so a later resume() can retry.
            set_error("load cancelled by pause()");
            state_.store(LLAMA_ENGINE_STATE_PAUSED);
            cv_lifecycle.notify_all();
            return LLAMA_ENGINE_ERR_CANCELLED;
        }
        set_error(err.empty() ? "failed to load model" : err);
        state_.store(LLAMA_ENGINE_STATE_UNLOADED);
        cv_lifecycle.notify_all();
        return LLAMA_ENGINE_ERR_LOAD_FAILED;
    }

    ctx  = std::move(new_ctx);
    meta = std::make_unique<server_context_meta>(ctx->get_meta());
    vocab = llama_model_get_vocab(llama_get_model(ctx->get_llama_context()));

    llama_engine_capabilities caps{};
    caps.has_mtmd        = meta->has_mtmd;
    caps.supports_vision = meta->has_inp_image;
    caps.supports_audio  = meta->has_inp_audio;

    // Reflect the jinja chat-template capabilities. Keys mirror
    // jinja::caps::to_map() in common/jinja/caps.cpp. Absent keys fall back
    // to false (e.g. when the template could not be analysed).
    auto caps_lookup = [&](const char * key) -> bool {
        auto it = meta->chat_template_caps.find(key);
        return it != meta->chat_template_caps.end() && it->second;
    };
    caps.supports_tool_calls = caps_lookup("supports_tool_calls");
    caps.supports_reasoning  = caps_lookup("supports_preserve_reasoning");

    cached_caps = caps;

    // IMPORTANT: check the pause-preempt flag BEFORE spawning loop_thread.
    // server_queue::start_loop() unconditionally sets `running = true` at
    // entry, so a terminate() raised before the thread actually runs would
    // be silently overwritten and the join() in teardown_locked() would
    // hang forever. This race is common when load_model() returns very fast
    // (typically during resume() with an OS-cached model file).
    if (was_preempted_by_pause) {
        state_.store(LLAMA_ENGINE_STATE_PAUSING);
        cv_lifecycle.notify_all();
        // teardown_locked() handles a non-joinable loop_thread gracefully,
        // so it's safe to call here without a started thread: it just drops
        // ctx/meta/vocab.
        teardown_locked(lock);
        state_.store(LLAMA_ENGINE_STATE_PAUSED);
        cv_lifecycle.notify_all();
        set_error("load preempted by pause()");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }

    loop_thread = std::thread([this]() {
        ctx->start_loop();
    });

    state_.store(LLAMA_ENGINE_STATE_READY);
    cv_lifecycle.notify_all();
    return LLAMA_ENGINE_OK;
}

void engine_core::preempt_all_streams_locked(std::unique_lock<std::mutex> & lock) {
    if (!ctx) {
        active_streams.clear();
        return;
    }

    auto reader_for_cancel = std::make_unique<server_response_reader>(ctx->get_response_reader());
    std::vector<server_task> cancel_tasks;
    for (auto * s : active_streams) {
        s->cancelled.store(true);
        for (int id : s->task_ids) {
            server_task c(SERVER_TASK_TYPE_CANCEL);
            c.id        = reader_for_cancel->get_new_id();
            c.id_target = id;
            cancel_tasks.push_back(std::move(c));
        }
        if (s->reader) {
            s->reader->stop();
        }
    }

    if (!cancel_tasks.empty()) {
        reader_for_cancel->post_tasks(std::move(cancel_tasks), /*front=*/true);
    }

    using namespace std::chrono;
    const auto deadline = steady_clock::now() + seconds(2);
    cv_streams.wait_until(lock, deadline, [&]() {
        return active_streams.empty();
    });
    // Forget any leftover streams: they hold a reader pointing into ctx, which
    // we are about to destroy. The Swift side always closes after next() fails,
    // so at worst this leaks the handle until the next call surfaces the error.
    active_streams.clear();
}

void engine_core::teardown_locked(std::unique_lock<std::mutex> & lock) {
    preempt_all_streams_locked(lock);

    if (ctx) {
        ctx->terminate();
        lock.unlock();
        if (loop_thread.joinable()) {
            loop_thread.join();
        }
        lock.lock();
        meta.reset();
        ctx.reset();
        vocab = nullptr;
    }
}

llama_engine_status engine_core::unload() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = state_.load();
    if (s == LLAMA_ENGINE_STATE_UNLOADED) {
        return LLAMA_ENGINE_OK;
    }
    if (s == LLAMA_ENGINE_STATE_LOADING || s == LLAMA_ENGINE_STATE_UNLOADING ||
        s == LLAMA_ENGINE_STATE_PAUSING || s == LLAMA_ENGINE_STATE_RESUMING) {
        set_error("engine is busy");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    state_.store(LLAMA_ENGINE_STATE_UNLOADING);
    teardown_locked(lock);
    last_params.reset();
    cached_caps.reset();
    state_.store(LLAMA_ENGINE_STATE_UNLOADED);
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::pause() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = state_.load();

    if (s == LLAMA_ENGINE_STATE_PAUSED) {
        return LLAMA_ENGINE_OK;
    }

    if (s == LLAMA_ENGINE_STATE_PAUSING) {
        // Another pause() is already tearing down. Wait for it to finish.
        cv_lifecycle.wait(lock, [&]() {
            return state_.load() == LLAMA_ENGINE_STATE_PAUSED;
        });
        return LLAMA_ENGINE_OK;
    }

    if (s == LLAMA_ENGINE_STATE_LOADING || s == LLAMA_ENGINE_STATE_RESUMING) {
        // Preempt an in-flight load (initial load or resume()). Signal the
        // progress callback to abort and wait until the loading thread
        // flips state_ to a terminal value.
        pause_requested_.store(true);
        cancel_load_.store(true);
        cv_lifecycle.wait(lock, [&]() {
            auto cur = state_.load();
            return cur == LLAMA_ENGINE_STATE_PAUSED
                || cur == LLAMA_ENGINE_STATE_UNLOADED
                || cur == LLAMA_ENGINE_STATE_READY;
        });
        auto resolved = state_.load();
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

    state_.store(LLAMA_ENGINE_STATE_PAUSING);
    cv_lifecycle.notify_all();
    teardown_locked(lock);
    // last_params intentionally retained for resume().
    state_.store(LLAMA_ENGINE_STATE_PAUSED);
    cv_lifecycle.notify_all();
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::resume() {
    std::unique_lock<std::mutex> lock(mtx);
    auto s = state_.load();
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
    if (state_.load() != LLAMA_ENGINE_STATE_READY) {
        if (state_.load() == LLAMA_ENGINE_STATE_PAUSED) {
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
    if (state_.load() != LLAMA_ENGINE_STATE_READY) {
        if (state_.load() == LLAMA_ENGINE_STATE_PAUSED) {
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

llama_engine_status engine_core::chat_completion(const std::string & request_json,
                                                 std::string & out_json)
{
    std::unique_lock<std::mutex> lock(mtx);
    if (state_.load() == LLAMA_ENGINE_STATE_PAUSED) {
        auto st = load_from_params_locked(lock, /*from_resume=*/true);
        if (st != LLAMA_ENGINE_OK) return st;
    }
    if (state_.load() != LLAMA_ENGINE_STATE_READY) {
        set_error("engine not loaded");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }

    task_builder::parsed_request parsed;
    try {
        parsed = task_builder::parse_oai_chat_request(request_json, meta->chat_params);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    auto reader = std::make_unique<server_response_reader>(ctx->get_response_reader());

    std::vector<server_task> tasks;
    try {
        tasks = task_builder::build_tasks(
            parsed, vocab, *last_params, meta->slot_n_ctx,
            meta->logit_bias_eog, meta->model_name,
            [&reader]() { return reader->get_new_id(); });
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    reader->post_tasks(std::move(tasks));

    lock.unlock();
    auto should_stop = []() { return false; };
    auto result = reader->wait_for_all(should_stop);
    lock.lock();

    if (result.error) {
        out_json = result_formatter::format_error(*result.error);
        return LLAMA_ENGINE_ERR_INFERENCE;
    }
    if (result.is_terminated || result.results.empty()) {
        set_error("inference terminated before any result");
        return LLAMA_ENGINE_ERR_INFERENCE;
    }
    try {
        out_json = result_formatter::format_non_stream(result.results);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::chat_completion_stream(const std::string & request_json,
                                                        stream_handle ** out_stream)
{
    *out_stream = nullptr;

    std::unique_lock<std::mutex> lock(mtx);
    if (state_.load() == LLAMA_ENGINE_STATE_PAUSED) {
        auto st = load_from_params_locked(lock, /*from_resume=*/true);
        if (st != LLAMA_ENGINE_OK) return st;
    }
    if (state_.load() != LLAMA_ENGINE_STATE_READY) {
        set_error("engine not loaded");
        return LLAMA_ENGINE_ERR_NOT_LOADED;
    }

    task_builder::parsed_request parsed;
    try {
        parsed = task_builder::parse_oai_chat_request(request_json, meta->chat_params);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    auto handle = std::make_unique<stream_handle>();
    handle->reader = std::make_unique<server_response_reader>(ctx->get_response_reader());

    std::vector<server_task> tasks;
    try {
        tasks = task_builder::build_tasks(
            parsed, vocab, *last_params, meta->slot_n_ctx,
            meta->logit_bias_eog, meta->model_name,
            [r = handle->reader.get()]() { return r->get_new_id(); });
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    for (const auto & t : tasks) {
        handle->task_ids.insert(t.id);
        for (const auto & c : t.child_tasks) {
            handle->task_ids.insert(c.id);
        }
    }

    handle->reader->post_tasks(std::move(tasks));

    // Peek the first result eagerly to surface immediate errors synchronously.
    stream_handle * raw = handle.get();
    lock.unlock();
    auto should_stop = [raw]() { return raw->cancelled.load(); };
    auto first = handle->reader->next(should_stop);
    lock.lock();

    if (!first) {
        // should_stop() fired before any result — caller cancelled before any output.
        set_error("cancelled");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }
    if (first->is_error()) {
        set_error("inference error");
        // Still return the error JSON via a single-shot stream.
    }

    handle->first_result = std::move(first);
    active_streams.insert(raw);
    *out_stream = handle.release();
    return LLAMA_ENGINE_OK;
}

llama_engine_status engine_core::stream_next(stream_handle * s,
                                             std::string & out_chunk, bool & out_done)
{
    if (s == nullptr) return LLAMA_ENGINE_ERR_INVALID_ARG;

    out_chunk.clear();
    out_done = false;

    server_task_result_ptr result;
    if (!s->first_chunk_sent && s->first_result) {
        result = std::move(s->first_result);
        s->first_chunk_sent = true;
    } else {
        if (s->cancelled.load()) {
            out_done = true;
            return LLAMA_ENGINE_ERR_CANCELLED;
        }
        if (!s->reader || !s->reader->has_next()) {
            out_done = true;
            return LLAMA_ENGINE_OK;
        }
        auto should_stop = [s]() { return s->cancelled.load(); };
        result = s->reader->next(should_stop);
        if (!result) {
            out_done = true;
            return s->cancelled.load() ? LLAMA_ENGINE_ERR_CANCELLED : LLAMA_ENGINE_OK;
        }
    }

    if (result->is_error()) {
        out_chunk = result_formatter::format_error(*result);
        out_done = true;
        return LLAMA_ENGINE_ERR_INFERENCE;
    }

    try {
        out_chunk = result_formatter::format_stream_chunk(*result);
    } catch (const std::exception & e) {
        out_done = true;
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    if (result->is_stop()) {
        out_done = true;
    }
    return LLAMA_ENGINE_OK;
}

void engine_core::stream_cancel(stream_handle * s) {
    if (s == nullptr) return;
    s->cancelled.store(true);

    std::unique_lock<std::mutex> lock(mtx);
    if (!ctx) return;

    std::vector<server_task> cancel_tasks;
    auto reader_for_cancel = std::make_unique<server_response_reader>(ctx->get_response_reader());
    for (int id : s->task_ids) {
        server_task c(SERVER_TASK_TYPE_CANCEL);
        c.id        = reader_for_cancel->get_new_id();
        c.id_target = id;
        cancel_tasks.push_back(std::move(c));
    }
    if (!cancel_tasks.empty()) {
        reader_for_cancel->post_tasks(std::move(cancel_tasks), /*front=*/true);
    }
    if (s->reader) s->reader->stop();
}

void engine_core::stream_close(stream_handle * s) {
    if (s == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(mtx);
        active_streams.erase(s);
        cv_streams.notify_all();
    }
    delete s;
}

} // namespace llama_engine
