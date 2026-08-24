#include "chat_route_adapter.hpp"

#include "json.h"

#include <cstring>
#include <utility>
#include <vector>

namespace llama_engine {

static std::unique_ptr<server_http_req> make_route_request(
    const std::string & path,
    const std::string & body,
    const std::function<bool()> & should_stop)
{
    return std::make_unique<server_http_req>(server_http_req{
        /* params       */ {},
        /* headers      */ {},
        /* path         */ path,
        /* query_string */ "",
        /* body         */ body,
        /* files        */ {},
        /* should_stop  */ should_stop,
    });
}

static bool starts_with(const std::string & s, const char * prefix) {
    return s.rfind(prefix, 0) == 0;
}

static std::vector<std::string> sse_data_payloads(const std::string & frame, bool & saw_done) {
    std::vector<std::string> out;
    std::string data;

    auto flush = [&]() {
        if (data.empty()) {
            return;
        }
        if (data == "[DONE]") {
            saw_done = true;
        } else {
            out.push_back(data);
        }
        data.clear();
    };

    size_t pos = 0;
    while (pos <= frame.size()) {
        size_t end = frame.find('\n', pos);
        std::string line = end == std::string::npos
            ? frame.substr(pos)
            : frame.substr(pos, end - pos);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }

        if (line.empty()) {
            flush();
        } else if (starts_with(line, "data:")) {
            std::string value = line.substr(std::strlen("data:"));
            if (!value.empty() && value.front() == ' ') {
                value.erase(value.begin());
            }
            if (!data.empty()) {
                data.push_back('\n');
            }
            data += std::move(value);
        }

        if (end == std::string::npos) {
            break;
        }
        pos = end + 1;
    }

    flush();
    return out;
}

static bool payload_is_error(const std::string & payload) {
    auto j = common_json::parse_no_throw(payload);
    return !j.is_discarded() && j.is_object() && j.contains("error");
}

static std::string error_message_from_json(const std::string & payload, const char * fallback) {
    auto j = common_json::parse_no_throw(payload);
    if (!j.is_discarded() && j.is_object() && j.contains("error") && j.at("error").is_object()) {
        const auto & err = j.at("error");
        if (err.contains("message") && err.at("message").is_string()) {
            return err.at("message").get<std::string>();
        }
    }
    return fallback;
}

static llama_engine_status status_from_http_error(int status) {
    if (status == 400) {
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }
    return LLAMA_ENGINE_ERR_INFERENCE;
}

static llama_engine_status completion_impl(
    const std::string & path,
    const server_http_context::handler_t & handler,
    const std::string & request_json,
    active_request & request_state,
    std::string & out_json,
    const chat_route_adapter::set_error_fn & set_error,
    const char * op_name,
    const char * stream_hint)
{
    out_json.clear();

    std::function<bool()> should_stop = [&request_state]() {
        return request_state.cancelled.load();
    };
    auto request = make_route_request(path, request_json, should_stop);

    server_http_res_ptr response;
    try {
        response = handler(*request);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    } catch (...) {
        set_error(std::string("unknown exception while handling ") + op_name);
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    if (request_state.cancelled.load()) {
        set_error("cancelled");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }
    if (!response) {
        set_error(std::string("empty response from ") + op_name + " route");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    if (response->is_stream()) {
        set_error(std::string(op_name) + " received a streaming response; use " + stream_hint + " or set stream=false");
        response.reset();
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    out_json = response->data;
    if (response->status >= 400) {
        const std::string fallback = std::string(op_name) + " failed";
        set_error(error_message_from_json(out_json, fallback.c_str()));
        return status_from_http_error(response->status);
    }
    return LLAMA_ENGINE_OK;
}

llama_engine_status chat_route_adapter::chat_completion(
    const std::shared_ptr<server_routes> & routes,
    const std::string & request_json,
    active_request & request_state,
    std::string & out_json,
    const set_error_fn & set_error)
{
    return completion_impl(
        "/v1/chat/completions",
        routes->post_chat_completions,
        request_json,
        request_state,
        out_json,
        set_error,
        "chat_completion",
        "chat_completion_stream()");
}

static llama_engine_status count_tokens_impl(
    const std::string & request_json,
    active_request & request_state,
    std::string & out_json,
    const chat_route_adapter::set_error_fn & set_error,
    const char * path,
    const server_http_context::handler_t & handler)
{
    out_json.clear();

    std::function<bool()> should_stop = [&request_state]() {
        return request_state.cancelled.load();
    };
    auto request = make_route_request(path, request_json, should_stop);

    server_http_res_ptr response;
    try {
        response = handler(*request);
    } catch (const std::exception & e) {
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    } catch (...) {
        set_error("unknown exception while counting tokens");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    if (request_state.cancelled.load()) {
        set_error("cancelled");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }
    if (!response) {
        set_error("empty response from token count route");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }
    if (response->is_stream()) {
        set_error("token count route returned a streaming response");
        response.reset();
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    out_json = response->data;
    if (response->status >= 400) {
        set_error(error_message_from_json(out_json, "token count failed"));
        return status_from_http_error(response->status);
    }
    return LLAMA_ENGINE_OK;
}

llama_engine_status chat_route_adapter::count_chat_tokens(
    const std::shared_ptr<server_routes> & routes,
    const std::string & request_json,
    active_request & request_state,
    std::string & out_json,
    const set_error_fn & set_error)
{
    return count_tokens_impl(
        request_json,
        request_state,
        out_json,
        set_error,
        "/v1/chat/completions/input_tokens",
        routes->post_chat_completions_tok);
}

std::unique_ptr<stream_handle> chat_route_adapter::make_stream_handle(
    const std::string & request_json)
{
    auto handle = std::make_unique<stream_handle>();
    stream_handle * raw = handle.get();
    handle->opening = true;
    handle->should_stop = [raw]() {
        return raw->cancelled.load();
    };
    handle->request = make_route_request("/v1/chat/completions", request_json, handle->should_stop);
    return handle;
}

static llama_engine_status open_registered_stream_impl(
    const server_http_context::handler_t & handler,
    inflight_registry & registry,
    std::unique_ptr<stream_handle> handle,
    stream_handle ** out_stream,
    const chat_route_adapter::set_error_fn & set_error,
    const char * op_name)
{
    *out_stream = nullptr;
    if (!handle) return LLAMA_ENGINE_ERR_INVALID_ARG;

    stream_handle * raw = handle.get();

    server_http_res_ptr response;
    try {
        response = handler(*handle->request);
    } catch (const std::exception & e) {
        registry.remove_stream(raw);
        {
            std::lock_guard<std::mutex> stream_lock(raw->mtx);
            raw->opening = false;
            raw->request.reset();
        }
        set_error(e.what());
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    } catch (...) {
        registry.remove_stream(raw);
        {
            std::lock_guard<std::mutex> stream_lock(raw->mtx);
            raw->opening = false;
            raw->request.reset();
        }
        set_error(std::string("unknown exception while opening ") + op_name + " stream");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    if (raw->cancelled.load()) {
        registry.remove_stream(raw);
        {
            std::lock_guard<std::mutex> stream_lock(raw->mtx);
            raw->opening = false;
            raw->response.reset();
            raw->request.reset();
        }
        set_error("cancelled");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }
    if (!response) {
        registry.remove_stream(raw);
        {
            std::lock_guard<std::mutex> stream_lock(raw->mtx);
            raw->opening = false;
            raw->request.reset();
        }
        set_error(std::string("empty response from ") + op_name + " route");
        return LLAMA_ENGINE_ERR_INTERNAL;
    }

    if (!response->is_stream() && response->status == 400) {
        registry.remove_stream(raw);
        {
            std::lock_guard<std::mutex> stream_lock(raw->mtx);
            raw->opening = false;
            raw->request.reset();
        }
        const std::string fallback = std::string("invalid ") + op_name + " request";
        set_error(error_message_from_json(response->data, fallback.c_str()));
        return LLAMA_ENGINE_ERR_INVALID_REQUEST;
    }

    bool cancelled = false;
    {
        std::lock_guard<std::mutex> stream_lock(raw->mtx);
        raw->opening = false;
        cancelled = raw->cancelled.load();
        if (cancelled) {
            raw->response.reset();
            raw->request.reset();
        } else if (response->is_stream()) {
            raw->response = std::move(response);
        } else {
            raw->single_shot_data   = response->data;
            raw->single_shot_status = response->status;
            raw->single_shot_ready  = true;
        }
    }

    if (cancelled) {
        registry.remove_stream(raw);
        set_error("cancelled");
        return LLAMA_ENGINE_ERR_CANCELLED;
    }

    *out_stream = handle.release();
    return LLAMA_ENGINE_OK;
}

llama_engine_status chat_route_adapter::open_registered_stream(
    const std::shared_ptr<server_routes> & routes,
    inflight_registry & registry,
    std::unique_ptr<stream_handle> handle,
    stream_handle ** out_stream,
    const set_error_fn & set_error)
{
    return open_registered_stream_impl(
        routes->post_chat_completions,
        registry,
        std::move(handle),
        out_stream,
        set_error,
        "chat completion");
}

llama_engine_status chat_route_adapter::open_stream(
    const std::shared_ptr<server_routes> & routes,
    const std::string & request_json,
    inflight_registry & registry,
    stream_handle ** out_stream,
    const set_error_fn & set_error)
{
    auto handle = make_stream_handle(request_json);
    stream_handle * raw = handle.get();
    registry.add_stream(raw);
    return open_registered_stream(routes, registry, std::move(handle), out_stream, set_error);
}

llama_engine_status chat_route_adapter::stream_next(stream_handle * s,
                                                    std::string & out_chunk,
                                                    bool & out_done,
                                                    const set_error_fn & set_error)
{
    if (s == nullptr) return LLAMA_ENGINE_ERR_INVALID_ARG;

    out_chunk.clear();
    out_done = false;

    std::unique_lock<std::mutex> lock(s->mtx);

    auto emit_payload = [&]() -> llama_engine_status {
        out_chunk = std::move(s->pending_chunks.front());
        s->pending_chunks.pop_front();
        if (payload_is_error(out_chunk)) {
            out_done = true;
            s->response.reset();
            s->request.reset();
            set_error(error_message_from_json(out_chunk, "inference error"));
            return LLAMA_ENGINE_ERR_INFERENCE;
        }
        if (s->response_done && s->pending_chunks.empty()) {
            out_done = true;
            s->response.reset();
            s->request.reset();
        }
        return LLAMA_ENGINE_OK;
    };

    if (!s->pending_chunks.empty()) {
        return emit_payload();
    }

    if (!s->single_shot_sent && s->single_shot_ready) {
        s->single_shot_sent = true;
        out_chunk = std::move(s->single_shot_data);
        out_done = true;
        if (s->single_shot_status >= 400) {
            set_error(error_message_from_json(out_chunk, "inference error"));
            return LLAMA_ENGINE_ERR_INFERENCE;
        }
        return LLAMA_ENGINE_OK;
    }

    if (s->cancelled.load()) {
        out_done = true;
        s->response.reset();
        s->request.reset();
        return LLAMA_ENGINE_ERR_CANCELLED;
    }

    while (s->response) {
        std::string frame;
        bool has_next = s->response->next(frame);
        bool saw_done = false;
        auto payloads = sse_data_payloads(frame, saw_done);
        for (auto & payload : payloads) {
            s->pending_chunks.push_back(std::move(payload));
        }
        if (!has_next || saw_done) {
            s->response_done = true;
        }
        if (!s->pending_chunks.empty()) {
            return emit_payload();
        }
        if (s->response_done) {
            out_done = true;
            s->response.reset();
            s->request.reset();
            return s->cancelled.load() ? LLAMA_ENGINE_ERR_CANCELLED : LLAMA_ENGINE_OK;
        }
    }

    out_done = true;
    return s->cancelled.load() ? LLAMA_ENGINE_ERR_CANCELLED : LLAMA_ENGINE_OK;
}

void chat_route_adapter::stream_cancel(stream_handle * s) {
    if (s == nullptr) return;
    s->cancelled.store(true);

    // Do not block cancellation behind stream_next(). stream_next() can be
    // waiting inside upstream server_response_reader::next(); the request's
    // should_stop callback observes `cancelled` and lets that wait unwind.
    // If no next() call is in progress, take the fast path and destroy the
    // response immediately, which posts upstream cancel tasks through
    // server_response_reader::stop().
    std::unique_lock<std::mutex> stream_lock(s->mtx, std::try_to_lock);
    if (!stream_lock.owns_lock() || s->opening) {
        return;
    }
    s->response.reset();
    s->request.reset();
    s->pending_chunks.clear();
}

void chat_route_adapter::stream_close(stream_handle * s) {
    if (s == nullptr) return;
    s->cancelled.store(true);
    {
        std::lock_guard<std::mutex> stream_lock(s->mtx);
        s->response.reset();
        s->request.reset();
        s->pending_chunks.clear();
    }
    delete s;
}

void chat_route_adapter::stream_preempt(stream_handle * s) {
    if (s == nullptr) return;
    s->cancelled.store(true);
    std::lock_guard<std::mutex> stream_lock(s->mtx);
    if (s->opening) {
        return;
    }
    // Destroying the route response destroys its server_response_reader,
    // which posts upstream cancel tasks through server_response_reader::stop().
    s->response.reset();
    s->request.reset();
    s->pending_chunks.clear();
}

} // namespace llama_engine
