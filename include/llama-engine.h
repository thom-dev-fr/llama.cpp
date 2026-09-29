#pragma once

#include <nlohmann/json.hpp>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Experimental C++ interface; no stable ABI is promised during extraction.
namespace llama_engine {
using json = nlohmann::ordered_json; // keeps the native field order

struct attachment {
    std::string name;
    std::vector<uint8_t> bytes;
};

enum class operation {
    completion, completions, chat, responses, messages, infill, transcription,
    embeddings, embeddings_openai, rerank, tokenize, detokenize, apply_template,
    chat_tokens, response_tokens, message_tokens, control, slots, slot_save,
    slot_restore, slot_erase, lora_list, lora_apply, properties, models, metrics, properties_update,
};

struct config {
    std::string model_path;
    int context_size = 512;
    int parallel = 1;
    int threads = 2;
    int gpu_layers = 0;
    int batch_size = 128;
    int micro_batch_size = 128;
    std::string chat_template;
    std::string mmproj_path;
    bool embeddings = false;
    int pooling_type = -1; // llama_pooling_type: -1 = model default
    std::string slot_save_path; // empty disables persistent slot actions
    std::vector<std::string> lora_paths;
    size_t max_tasks = 64;          // includes queued, active and cancelling tasks
    size_t max_events = 256;        // per request, before JSON conversion
    size_t max_request_bytes = 16 * 1024 * 1024;
    json generation_defaults = json::object();
};

enum class event_type { payload, success, error, cancelled, timeout };
struct event {
    event_type type = event_type::success;
    json data = nullptr; // null payload marks generation start (native streaming contract)
    // Errors have a stable category and optional native error details in data.
    std::string category;
    std::string message;
    bool terminal() const {
        return type == event_type::success || type == event_type::error || type == event_type::cancelled;
    }
};

namespace detail { struct request_state; struct engine_impl; }

// A handle owns its buffers, independent of engine lifetime. Destroying it cancels
// unfinished work. next()/result() share one serialized reader; cancel() may run
// concurrently. Destruction must not race a method on that same C++ object.
class request {
public:
    explicit request(std::shared_ptr<detail::request_state> state);
    ~request();
    request(const request &) = delete;
    request & operator=(const request &) = delete;
    event next();
    event next_for(std::chrono::milliseconds timeout);
    // Non-streaming only: returns the complete native object/array on success.
    // Call instead of next(). Throws std::logic_error on a streaming request;
    // use next() to keep streaming deltas.
    event result();
    void cancel();
private:
    std::shared_ptr<detail::request_state> state;
};

class engine {
public:
    // Operational load/configuration errors are returned in error; nullptr on failure.
    static std::unique_ptr<engine> create(const config & settings, event & error);
    ~engine();
    engine(const engine &) = delete;
    engine & operator=(const engine &) = delete;
    // Synchronous preparation on the submitting thread, decoding on owned threads.
    // JSON and attachments are passed by value and consumed/owned before return.
    // Native /completion schema, including batch prompts and n, without HTTP.
    // Existing JSON contracts, selected by operation, without HTTP paths.
    std::unique_ptr<request> submit(operation op, json input = json::object(),
                                    std::vector<attachment> files = {});
    std::unique_ptr<request> completion(json input, std::vector<attachment> files = {});
    // Concurrent, idempotent. Closes admissions, cancels, wakes readers and joins.
    // Surviving requests drain buffered payloads then see their sole terminal result;
    // every subsequent next() returns that same terminal result immediately.
    // Submissions after stop return an explicitly cancelled request.
    void stop();
private:
    engine();
    std::unique_ptr<detail::engine_impl> impl;
};
} // namespace llama_engine
