#pragma once
#include "llama-engine.h"
#include "server-queue.h"
#include <map>

struct server_context;

// Process-lifetime backend initialization, shared by local engines and legacy
// consumers. Does not change logging, signals, NUMA policy or process priority.
void engine_backend_init();

namespace llama_engine { namespace detail {
struct request_state {
    std::mutex mutex;
    std::mutex reader_mutex;
    std::condition_variable ready;
    std::deque<server_task_result_ptr> pending;
    std::vector<task_result_state> conversion;
    std::vector<json> complete;
    size_t capacity = 256;
    size_t remaining = 0;
    bool stream = false;
    bool finished = false;
    event terminal;
    server_task_result_ptr native_error;
    std::function<void()> cancel_work;

    void push(server_task_result_ptr result);
    void finish(event end);
    void cancel();
    event read(std::chrono::milliseconds timeout);
};

struct runtime {
    std::mutex mutex;
    std::mutex join_mutex;
    server_context * context = nullptr;
    bool stopped = false;
    std::thread decoder;
    std::vector<std::weak_ptr<request_state>> requests;
    config limits;

    void cancel(const std::unordered_set<int> & ids);
};

std::unique_ptr<request> submit(const std::shared_ptr<runtime> & run, json input,
                              std::vector<attachment> files = {});
void request_stop(const std::shared_ptr<runtime> & run);
void stop(const std::shared_ptr<runtime> & run);
} }
