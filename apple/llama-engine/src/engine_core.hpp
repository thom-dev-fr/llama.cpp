#pragma once

#include "llama_engine.h"

#include "server-context.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace llama_engine {

struct stream_handle {
    std::unique_ptr<server_response_reader> reader;
    std::unordered_set<int>                 task_ids;
    std::atomic<bool>                       cancelled{false};
    bool                                    first_chunk_sent = false;
    // The first chunk is peeked eagerly in chat_completion_stream() so we can
    // promote initial errors into a synchronous failure (matches OAI behaviour
    // where a stream request that fails immediately is returned as a non-stream
    // error). Stored here to be consumed on the first stream_next() call.
    server_task_result_ptr                  first_result;
};

// Top-level orchestrator. Holds exactly one server_context at a time, drives
// the main loop on a dedicated thread, translates between the public C config
// and internal common_params, and dispatches chat completion requests through
// server_response_reader.
class engine_core {
public:
    engine_core();
    ~engine_core();

    engine_core(const engine_core &)             = delete;
    engine_core & operator=(const engine_core &) = delete;

    // Lifecycle
    llama_engine_status load(const llama_engine_config & cfg);
    llama_engine_status unload();
    llama_engine_status pause();
    llama_engine_status resume();

    llama_engine_state state() const;

    // Capabilities reflected from the currently loaded server_context meta.
    // Returns LLAMA_ENGINE_ERR_NOT_LOADED if there is no loaded model.
    llama_engine_status capabilities(llama_engine_capabilities & out);

    const char * last_error();

    // Tokenization
    llama_engine_status tokenize(const std::string & text, bool add_special,
                                 std::vector<int32_t> & out);
    llama_engine_status detokenize(const std::vector<int32_t> & tokens,
                                   std::string & out);

    // Inference
    llama_engine_status chat_completion(const std::string & request_json,
                                        std::string & out_json);
    llama_engine_status chat_completion_stream(const std::string & request_json,
                                               stream_handle ** out_stream);
    llama_engine_status stream_next(stream_handle * stream,
                                    std::string & out_chunk, bool & out_done);
    void                stream_cancel(stream_handle * stream);
    void                stream_close(stream_handle * stream);

private:
    llama_engine_status load_locked(const llama_engine_config & cfg,
                                    std::unique_lock<std::mutex> & lock);
    // `from_resume == true` makes the entry transient state RESUMING instead
    // of LOADING, so observers can distinguish a fresh load from a
    // pause-recovery reload. Cancellation/preemption semantics are otherwise
    // identical.
    llama_engine_status load_from_params_locked(std::unique_lock<std::mutex> & lock,
                                                bool from_resume);
    void                teardown_locked(std::unique_lock<std::mutex> & lock);
    void                preempt_all_streams_locked(std::unique_lock<std::mutex> & lock);

    void                set_error(std::string msg);

    mutable std::mutex      mtx;
    std::condition_variable cv_streams;
    // Signals transitions of state_. Used by pause() to wait for an in-flight
    // load_from_params_locked() to observe the cancellation flag.
    std::condition_variable cv_lifecycle;

    std::atomic<llama_engine_state> state_{LLAMA_ENGINE_STATE_UNLOADED};
    std::string                     last_error_;

    // Set by pause() when called during LOADING/RESUMING. Read by the
    // progress callback installed on common_params.load_progress_callback;
    // returning false aborts llama_model_load_from_file and causes
    // server_context::load_model() to return false.
    std::atomic<bool> cancel_load_{false};
    // Distinguishes an explicit pause-preemption from other load failures,
    // so the post-load path can transition to PAUSED (keeping last_params)
    // rather than UNLOADED.
    std::atomic<bool> pause_requested_{false};

    std::optional<common_params>           last_params;
    std::unique_ptr<server_context>        ctx;
    std::thread                            loop_thread;
    std::unique_ptr<server_context_meta>   meta;
    const llama_vocab *                    vocab = nullptr;
    struct mtmd_context *                  mctx  = nullptr; // unused in v1

    // Capabilities are captured right after load_model() and kept across
    // pause/resume transitions, where `meta` is dropped. Only valid when
    // last_params has a value.
    std::optional<llama_engine_capabilities> cached_caps;

    std::set<stream_handle *> active_streams;

    static std::once_flag     backend_once;
    static std::atomic<int>   log_verbosity;
};

} // namespace llama_engine
