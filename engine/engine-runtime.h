#pragma once
#include "llama-engine.h"
#include "server-queue.h"
#include <atomic>
#include <map>

struct server_context;

// Process-lifetime backend initialization, shared by the engines and the
// server's single model. Does not change logging, signals, NUMA policy or process priority.
void engine_backend_init();

namespace llama_engine { namespace detail {
// A converted native payload (status payload), or a timeout/terminal status.
struct native_item {
    event status;
    server_task_result_ptr result;
};

struct request_state {
    std::mutex mutex;
    std::mutex reader_mutex;
    std::condition_variable ready;
    std::deque<server_task_result_ptr> pending;
    std::vector<task_result_state> conversion;
    std::vector<json> complete;
    size_t capacity = 256;
    size_t remaining = 0;
    std::atomic<bool> stream {false}; // readers may check it while a queued request is prepared
    bool fail_on_no_slot = false;
    task_response_type format = TASK_RESPONSE_TYPE_NONE;
    int32_t sse_ping_interval = 30;
    std::function<::json(::json)> assemble;
    bool finished = false;
    event terminal;
    server_task_result_ptr native_error;
    std::function<void()> cancel_work;
    // Called once, outside the state lock, when the terminal result is decided.
    std::function<void()> on_finish;

    // Installs on_finish unless the request is already finished.
    bool attach_finish_hook(std::function<void()> hook);
    // Replaces cancel_work unless the request is already finished.
    bool attach_cancel(std::function<void()> cancel);
    void push(server_task_result_ptr result);
    void finish(event end);
    void cancel();
    event read(std::chrono::milliseconds timeout);
    // Same serialized reader, without conversion to the public JSON type. Used by
    // the HTTP adapter to format the native result exactly as before the engine.
    native_item read_native(std::chrono::milliseconds timeout);
private:
    native_item next_native(std::chrono::milliseconds timeout);
};

struct runtime {
    std::mutex mutex;
    std::mutex join_mutex;
    server_context * context = nullptr;
    bool stopped = false;
    size_t preparing = 0;             // submissions preparing tasks outside the mutex
    std::condition_variable prepared;
    std::thread decoder;
    std::vector<std::weak_ptr<request_state>> requests;
    config limits;
    std::mutex snapshot_mutex;
    server_metrics sleep_metrics;
    ::json sleep_models;
    ::json sleep_properties;
    bool reset_metrics_on_wake = false;

    void cancel(const std::unordered_set<int> & ids);
};

// Limits of the HTTP server: as before the engine, requests are queued without
// limit, results are buffered without limit and body size is left to the
// transport. The public engine keeps bounded defaults for embedding.
void apply_http_compat_limits(runtime & run);

std::unique_ptr<request> submit(const std::shared_ptr<runtime> & run, json input,
                              std::vector<attachment> files = {}, operation op = operation::completion);
std::shared_ptr<request_state> submit_state(const std::shared_ptr<runtime> & run, json input,
                                            std::vector<attachment> files = {}, operation op = operation::completion);
// HTTP adapter entry point: native JSON already parsed by the transport.
void submit_native(const std::shared_ptr<runtime> & run, const std::shared_ptr<request_state> & state,
                   const ::json & data, operation op = operation::completion,
                   const std::vector<attachment> & files = {});
// Surviving requests end with reason (cancelled/stopped by default).
void request_stop(const std::shared_ptr<runtime> & run, const event & reason = {event_type::cancelled, nullptr, "stopped", "Engine stopped"});
// Prepares public JSON for submit_native: size limit, generation defaults.
// Returns false after finishing state with an invalid_request error.
bool prepare_input(const config & limits, request_state & state, const json & input,
                   const std::vector<attachment> & files, operation op, ::json & data);
// Engine limits and model options (build_params); error explains a failure.
bool valid_config(const config & settings, std::string & error);
void stop(const std::shared_ptr<runtime> & run);
} }
