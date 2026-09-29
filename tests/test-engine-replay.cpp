#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../tools/server/server-stream.h"
#include "engine-runtime.h"
#include <cassert>
#include <future>

using namespace std::chrono_literals;
using llama_engine::event_type;
using llama_engine::detail::request_state;

struct chunk_result : server_task_result {
    std::string chunk;
    bool last = false;
    bool is_stop() override { return last; }
    ::json to_json() override { return chunk; }
};
static void send(const std::shared_ptr<request_state> & state, std::string text, bool last = false) {
    auto item = std::make_unique<chunk_result>();
    item->chunk = std::move(text); item->last = last;
    state->push(std::move(item));
}
struct producer : server_res_spipe {
    llama_engine::request request;
    producer(const server_http_req & req, std::shared_ptr<request_state> state,
             std::function<void()> entered = [] {}) : request(std::move(state)) {
        set_req(&req);
        set_next([this, entered](std::string & output) {
            entered();
            for (;;) {
                if (should_stop()) { request.cancel(); return false; }
                auto item = request.next_for(10ms);
                if (item.type == event_type::timeout) { continue; }
                if (item.terminal()) { return false; }
                output = item.data.get<std::string>();
                return true;
            }
        });
    }
};
int main() {
    server_stream_session_manager_start();
    bool disconnected = false;
    std::function<bool()> connection = [&] { return disconnected; };
    std::function<bool()> connected = [] { return false; };
    server_http_req origin {{}, {{"X-Conversation-Id", "engine-replay"}}, {}, {}, {}, {}, connection};
    server_http_req lookup {{{"conv_id", "engine-replay"}, {"from", "0"}}, {}, {}, {}, {}, {}, connected};
    auto get = server_stream_make_get_handler();
    auto erase = server_stream_make_delete_handler();
    auto state = std::make_shared<request_state>();
    state->remaining = 1;
    auto live = std::make_unique<producer>(origin, state);
    send(state, "data: first\n\n");
    std::string output;
    assert(live->next(output) && output == "data: first\n\n");
    disconnected = true;
    assert(!live->should_stop()); // opt-in replay owns the still-active request
    send(state, "data: final\n\n", true);
    live->on_complete();
    live.reset();
    auto replay = get(lookup);
    assert(replay->status == 200);
    output.clear();
    assert(replay->next(output) && output == "data: first\n\ndata: final\n\n");
    assert(!replay->next(output));
    lookup.params["from"] = "13";
    replay = get(lookup);
    output.clear();
    assert(replay->next(output) && output == "data: final\n\n");

    // Replacement terminates the old producer, without touching the new one.
    auto old_state = std::make_shared<request_state>(); old_state->remaining = 1;
    auto old = std::make_unique<producer>(origin, old_state);
    state = std::make_shared<request_state>(); state->remaining = 1;
    live = std::make_unique<producer>(origin, state);
    assert(old->should_stop() && !live->should_stop());
    old.reset();
    assert(old_state->read(0ms).type == event_type::cancelled);

    // Force replay eviction with controlled bytes, without generating millions
    // of tokens or relying on backend speed.
    send(state, std::string(4 * 1024 * 1024 + 16, 'x'), true);
    output.clear();
    assert(live->next(output));
    live->on_complete(); live.reset();
    lookup.params["from"] = "0";
    assert(get(lookup)->status == 400);
    lookup.params["from"] = "16";
    replay = get(lookup);
    assert(replay->status == 200);
    output.clear();
    assert(replay->next(output) && output.size() == 4 * 1024 * 1024);

    // Stop while the disconnected producer is blocked draining the engine.
    state = std::make_shared<request_state>(); state->remaining = 1;
    std::promise<void> entered;
    live = std::make_unique<producer>(origin, state, [&] { entered.set_value(); });
    auto drain = std::async(std::launch::async, [&] { live->on_complete(); });
    entered.get_future().wait();
    assert(erase(lookup)->status == 204);
    assert(drain.wait_for(2s) == std::future_status::ready);
    drain.get(); live.reset();
    assert(state->read(0ms).type == event_type::cancelled);
    assert(get(lookup)->status == 404);

    // Shutdown wakes a blocked replay reader; no polling sleep is needed.
    state = std::make_shared<request_state>(); state->remaining = 1;
    live = std::make_unique<producer>(origin, state);
    lookup.params["from"] = "0";
    replay = get(lookup);
    auto reader = std::async(std::launch::async, [&] { std::string chunk; return replay->next(chunk); });
    server_stream_session_manager_stop();
    assert(reader.wait_for(2s) == std::future_status::ready && !reader.get());
    live.reset();

    // Without a conversation id, disconnection cancels the request.
    origin.headers.clear();
    state = std::make_shared<request_state>(); state->remaining = 1;
    live = std::make_unique<producer>(origin, state);
    assert(!live->next(output));
    assert(state->read(0ms).type == event_type::cancelled);
}
