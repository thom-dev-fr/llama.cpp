#pragma once

#include "llama_engine.h"

#include "inflight_registry.hpp"
#include "server-context.h"

#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>

namespace llama_engine {

struct stream_handle {
    std::mutex                              mtx;
    std::atomic<bool>                       cancelled{false};
    std::function<bool()>                   should_stop;
    std::unique_ptr<server_http_req>        request;
    server_http_res_ptr                     response;
    std::deque<std::string>                 pending_chunks;
    std::string                             single_shot_data;
    int                                     single_shot_status = 200;
    bool                                    single_shot_ready  = false;
    bool                                    single_shot_sent   = false;
    bool                                    response_done      = false;
    bool                                    opening            = false;
};

// Adapter from LlamaEngine's in-process chat interface to upstream
// server_routes. It owns the details of synthetic server_http_req construction,
// upstream SSE frame normalisation, OpenAI-compatible error payload mapping,
// and stream handle cancellation/ownership.
class chat_route_adapter {
public:
    using set_error_fn = std::function<void(std::string)>;

    static llama_engine_status chat_completion(
        const std::shared_ptr<server_routes> & routes,
        const std::string & request_json,
        active_request & request_state,
        std::string & out_json,
        const set_error_fn & set_error);

    static llama_engine_status count_chat_tokens(
        const std::shared_ptr<server_routes> & routes,
        const std::string & request_json,
        active_request & request_state,
        std::string & out_json,
        const set_error_fn & set_error);

    static std::unique_ptr<stream_handle> make_stream_handle(
        const std::string & request_json);

    // Opens a stream handle that the caller already registered with
    // `registry`. This lets Engine Core publish the in-flight stream while it
    // still holds its own mutex, before pause / unload can drain the registry.
    static llama_engine_status open_registered_stream(
        const std::shared_ptr<server_routes> & routes,
        inflight_registry & registry,
        std::unique_ptr<stream_handle> handle,
        stream_handle ** out_stream,
        const set_error_fn & set_error);

    static llama_engine_status open_stream(
        const std::shared_ptr<server_routes> & routes,
        const std::string & request_json,
        inflight_registry & registry,
        stream_handle ** out_stream,
        const set_error_fn & set_error);

    static llama_engine_status stream_next(stream_handle * stream,
                                           std::string & out_chunk,
                                           bool & out_done,
                                           const set_error_fn & set_error);

    static void stream_cancel(stream_handle * stream);
    static void stream_close(stream_handle * stream);
    static void stream_preempt(stream_handle * stream);
};

} // namespace llama_engine
