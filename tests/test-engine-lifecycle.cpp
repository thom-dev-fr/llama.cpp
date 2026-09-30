#ifdef NDEBUG
#undef NDEBUG
#endif
#include "engine-runtime.h"
#include "engine-context.h"
#include <cassert>
#include <future>
using namespace llama_engine;
using namespace llama_engine::detail;
using namespace std::chrono_literals;

struct fake_result : server_task_result {
    bool last;
    explicit fake_result(int id, bool last) : last(last) { this->id = id; }
    bool is_stop() override { return last; }
    ::json to_json() override { return {{"stop", last}}; }
};
static server_task_result_ptr payload(int id, bool last = false) {
    return std::make_unique<fake_result>(id, last);
}

int main() {
    // Test the actual decoder delivery seam, including admission leases that
    // cannot be recycled before cancellation is acknowledged by the decoder.
    server_response responses;
    server_queue tasks;
    auto slow = std::make_shared<request_state>();
    slow->capacity = 1; slow->remaining = 1;
    slow->cancel_work = [&] { responses.cancel_sinks({1}, tasks); };
    assert(responses.add_sinks({1}, 1, [slow](server_task_result_ptr value) { slow->push(std::move(value)); }));
    responses.send(payload(1));
    responses.send(payload(1));
    assert(slow->finished && slow->terminal.category == "queue_full");
    assert(slow->pending.size() == 1);
    request slow_reader(slow);
    assert(slow_reader.next().type == event_type::payload);
    assert(slow_reader.next().category == "queue_full");
    assert(slow_reader.next().category == "queue_full");
    auto sink = [](server_task_result_ptr) {};
    assert(!responses.add_sinks({2}, 1, sink));
    responses.cancel_sinks({1}, tasks); // coalesced, still one cancellation
    responses.finish_sink(1);          // decoder acknowledgement
    assert(responses.add_sinks({2}, 1, sink));
    responses.send(payload(2, true));
    assert(responses.add_sinks({3}, 1, sink));

    for (int i = 0; i < 100; ++i) {
        auto state = std::make_shared<request_state>();
        state->remaining = 1;
        request handle(state);
        std::promise<void> go;
        auto gate = go.get_future().share();
        auto finish = std::async(std::launch::async, [&] { gate.wait(); state->finish({event_type::success, nullptr, {}, {}}); });
        auto cancel = std::async(std::launch::async, [&] { gate.wait(); handle.cancel(); });
        auto shutdown = std::async(std::launch::async, [&] { gate.wait(); state->finish({event_type::cancelled, nullptr, "stopped", "stopped"}); });
        auto reader = std::async(std::launch::async, [&] { return handle.next(); });
        go.set_value();
        finish.get(); cancel.get(); shutdown.get();
        assert(reader.wait_for(1s) == std::future_status::ready);
        auto end = reader.get();
        assert(end.terminal() && handle.next().type == end.type);
    }
    auto abandoned = std::make_shared<request_state>();
    int cancelled = 0;
    abandoned->cancel_work = [&] { ++cancelled; };
    { request handle(abandoned); }
    assert(cancelled == 1 && abandoned->terminal.type == event_type::cancelled);

    // HTTP compatibility: the server queues any number of requests and buffers
    // every result, as before the engine. Public engine defaults stay bounded.
    runtime http;
    assert(http.limits.max_tasks == config().max_tasks && http.limits.max_events == config().max_events);
    apply_http_compat_limits(http);
    server_response http_responses;
    std::unordered_set<int> many_ids;
    for (int id = 100; id < 100 + 1000; ++id) { many_ids.insert(id); }
    assert(http_responses.add_sinks(many_ids, http.limits.max_tasks, sink));
    auto buffered = std::make_shared<request_state>();
    buffered->capacity = http.limits.max_events;
    buffered->remaining = 1;
    for (int i = 0; i < 1000; ++i) { buffered->push(payload(100)); }
    assert(!buffered->finished && buffered->pending.size() == 1000);

    // A controlled decoder stands in for a backend call. It stays blocked until
    // explicitly released, so cancellation/stop do not depend on model speed.
    server_context context;
    auto run = context.runtime;
    auto active = std::make_shared<request_state>();
    auto queued = std::make_shared<request_state>();
    active->remaining = queued->remaining = 1;
    active->cancel_work = [run] { run->cancel({10}); };
    queued->cancel_work = [run] { run->cancel({11}); };
    request active_handle(active), queued_handle(queued);
    run->requests = {active, queued};
    assert(context.responses().add_sinks({10}, 2, [active](server_task_result_ptr p) { active->push(std::move(p)); }));
    assert(context.responses().add_sinks({11}, 2, [queued](server_task_result_ptr p) { queued->push(std::move(p)); }));
    std::promise<void> decoding, release_decode;
    auto release = release_decode.get_future().share();
    context.tasks().on_new_task([&](server_task && task, bool) {
        if (task.id == 10) { decoding.set_value(); release.wait(); }
        assert(task.id != 11); // cancelled while queued: never executed
        if (task.type == SERVER_TASK_TYPE_CANCEL) { context.responses().finish_sink(task.id_target); }
        return true;
    });
    context.tasks().on_update_slots([] {});
    server_task work(SERVER_TASK_TYPE_COMPLETION);
    work.id = 10;
    context.tasks().post(std::move(work));
    run->decoder = std::thread([&] { context.tasks().start_loop(); });
    decoding.get_future().wait();
    work = server_task(SERVER_TASK_TYPE_COMPLETION);
    work.id = 11;
    context.tasks().post(std::move(work));
    queued_handle.cancel();
    assert(queued_handle.next().type == event_type::cancelled);
    auto blocked_reader = std::async(std::launch::async, [&] { return active_handle.next(); });
    auto shutdown = std::async(std::launch::async, [&] { stop(run); });
    assert(blocked_reader.wait_for(1s) == std::future_status::ready);
    assert(blocked_reader.get().type == event_type::cancelled);
    assert(shutdown.wait_for(0ms) == std::future_status::timeout); // backend still held
    release_decode.set_value();
    assert(shutdown.wait_for(1s) == std::future_status::ready);
    shutdown.get();

    // Stop before the decoder enters its loop must not be lost.
    server_queue early_stop;
    early_stop.on_new_task([](server_task &&, bool) { return true; });
    early_stop.on_update_slots([] {});
    early_stop.terminate();
    auto loop = std::async(std::launch::async, [&] { early_stop.start_loop(); });
    assert(loop.wait_for(1s) == std::future_status::ready);
    loop.get();
}
