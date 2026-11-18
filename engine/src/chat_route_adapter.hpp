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
    // speech stream: the frames are raw PCM bytes, not SSE
    bool                                    audio              = false;
    std::string                             content_type;
};

// raw F32 LE PCM, channels interleaved
struct pcm_format {
    int32_t sample_rate = 0;
    int32_t n_channels  = 0;

    bool valid() const { return sample_rate > 0 && n_channels > 0; }
    size_t frame_size() const { return (size_t) n_channels * sizeof(float); }
    // bytes of the whole frames in the first `n_bytes`
    size_t whole_frames(size_t n_bytes) const { return valid() ? n_bytes - n_bytes % frame_size() : 0; }
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

    // Speech generation through the /tts route: `request_json` gets
    // "response_format": "pcm" (F32 LE samples) and "stream".
    // `out_format` comes from the content type of the response.
    static llama_engine_status speech(
        const std::shared_ptr<server_routes> & routes,
        const std::string & request_json,
        active_request & request_state,
        std::string & out_pcm,
        pcm_format & out_format,
        const set_error_fn & set_error);

    // nullptr with `error` set when `request_json` is not a JSON object
    static std::unique_ptr<stream_handle> make_speech_stream_handle(
        const std::string & request_json,
        std::string & error);

    static llama_engine_status open_registered_speech_stream(
        const std::shared_ptr<server_routes> & routes,
        inflight_registry & registry,
        std::unique_ptr<stream_handle> handle,
        stream_handle ** out_stream,
        const set_error_fn & set_error);

    // format of "audio/pcm;rate=24000;channels=2;...", 1 channel when "channels" is absent
    // zeroed if the rate or the channel count is missing or invalid
    static pcm_format parse_pcm_format(const std::string & content_type);

    static void stream_cancel(stream_handle * stream);
    static void stream_close(stream_handle * stream);
    static void stream_preempt(stream_handle * stream);
};

} // namespace llama_engine
