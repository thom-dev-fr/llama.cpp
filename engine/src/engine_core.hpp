#pragma once

#include "llama_engine.h"

#include "chat_route_adapter.hpp"
#include "engine_lifecycle.hpp"
#include "inflight_registry.hpp"
#include "server-context.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace llama_engine {

// Top-level orchestrator. Holds exactly one server_context at a time, drives
// the main loop on a dedicated thread, translates between the public C config
// and internal common_params, and dispatches chat completion requests through
// upstream server_routes.
class engine_core {
public:
    engine_core() = default;
    ~engine_core();

    engine_core(const engine_core &)             = delete;
    engine_core & operator=(const engine_core &) = delete;

    // Lifecycle
    llama_engine_status load(const llama_engine_config & cfg);
    llama_engine_status unload();
    llama_engine_status pause();
    llama_engine_status resume();

    llama_engine_state state() const;

    // Returns true iff Multi-Token Prediction speculative decoding is wired
    // up against the currently loaded model. False when not loaded, or when
    // load_model() did not enable a DRAFT_MTP speculative type.
    bool is_mtp_active() const;

    const char * last_error();

    static void set_log_verbosity(int verbosity);

    // Tokenization
    llama_engine_status tokenize(const std::string & text, bool add_special,
                                 std::vector<int32_t> & out);
    llama_engine_status detokenize(const std::vector<int32_t> & tokens,
                                   std::string & out);
    llama_engine_status count_chat_tokens(const std::string & request_json,
                                          std::string & out_json);

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
    struct admitted_request {
        std::shared_ptr<server_routes> routes;
        inflight_registry::request_guard guard;
    };

    struct admitted_stream {
        std::shared_ptr<server_routes> routes;
        std::unique_ptr<stream_handle> handle;
    };

    llama_engine_status admit_request_locked(std::unique_lock<std::mutex> & lock,
                                             active_request & req,
                                             admitted_request & out);
    llama_engine_status admit_stream_locked(std::unique_lock<std::mutex> & lock,
                                            const std::string & request_json,
                                            admitted_stream & out);

    llama_engine_status load_locked(const llama_engine_config & cfg,
                                    std::unique_lock<std::mutex> & lock);
    // `from_resume == true` makes the entry transient state RESUMING instead
    // of LOADING, so observers can distinguish a fresh load from a
    // pause-recovery reload. Cancellation/preemption semantics are otherwise
    // identical.
    llama_engine_status load_from_params_locked(std::unique_lock<std::mutex> & lock,
                                                bool from_resume);
    void                teardown_locked(std::unique_lock<std::mutex> & lock);

    static void         ensure_backend_initialized();

    void                set_error(std::string msg);

    mutable std::mutex      mtx;

    engine_lifecycle  lifecycle;
    inflight_registry registry;
    std::string       last_error_;

    std::optional<common_params>           last_params;
    std::unique_ptr<server_context>        ctx;
    std::shared_ptr<server_routes>         routes;
    std::thread                            loop_thread;
    std::unique_ptr<server_context_meta>   meta;
    const llama_vocab *                    vocab = nullptr;
    struct mtmd_context *                  mctx  = nullptr; // unused in v1

    static std::once_flag     backend_once;
    static std::atomic<int>   log_verbosity;
};

} // namespace llama_engine
