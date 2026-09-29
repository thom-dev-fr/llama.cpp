#ifdef NDEBUG
#undef NDEBUG
#endif
// Public consumer: no common_params, internal queues, server or loop entry point.
#include "llama-engine.h"
#include <cassert>
#include <future>
#include <filesystem>
#include <fstream>
#include <iostream>

using namespace llama_engine;
using namespace std::chrono_literals;

static json prompt(bool stream = false, int count = 8) {
    return {{"prompt", "Once upon a time"}, {"n_predict", count}, {"stream", stream},
            {"ignore_eos", true}, {"temperature", 0}, {"cache_prompt", false}};
}
static event terminal(request & req) {
    for (;;) {
        auto e = req.next_for(10s);
        assert(e.type != event_type::timeout);
        if (e.terminal()) { return e; }
    }
}
static std::unique_ptr<engine> create(config settings) {
    event error;
    auto engine = engine::create(settings, error);
    if (!engine) { std::cerr << error.category << ": " << error.message << '\n'; }
    assert(engine);
    return engine;
}

int main(int argc, char ** argv) {
    event error;
    assert(!engine::create({}, error));
    assert(error.category == "invalid_config");
    config settings;
    settings.model_path = "/nonexistent/llama-engine-test.gguf";
    assert(!engine::create(settings, error));
    assert(error.category == "load_failed");
    const auto corrupt = std::filesystem::temp_directory_path() /
        ("test-engine-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".gguf");
    { std::ofstream file(corrupt, std::ios::binary); file << "invalid gguf fixture"; }
    settings.model_path = corrupt.string();
    auto failed = engine::create(settings, error);
    std::filesystem::remove(corrupt);
    assert(!failed && error.category == "load_failed");
    if (argc != 2) {
        std::cout << "PASS configuration/load errors; GGUF integration NOT RUN (pass model path)\n";
        return 0;
    }
    settings.model_path = argv[1];
    auto first = create(settings);
    auto invalid = first->completion(json::object());
    assert(terminal(*invalid).category == "invalid_request");
    assert(terminal(*first->completion({{"prompt", "x"}, {"n", 1000000000}})).category == "invalid_request");
    assert(terminal(*first->completion(prompt(), {{"image", {1, 2, 3}}})).category == "invalid_request");
    auto full = first->completion(prompt())->result();
    assert(full.type == event_type::success);
    assert(full.data["timings"]["predicted_n"] == 8);
    auto streaming = first->completion(prompt(true));
    int final_payloads = 0;
    for (;;) {
        auto e = streaming->next_for(10s);
        assert(e.type != event_type::timeout);
        if (e.terminal()) { assert(e.type == event_type::success); break; }
        if (e.data.is_object() && e.data.value("stop", false)) { ++final_payloads; }
    }
    assert(final_payloads == 1);
    assert(streaming->next().type == event_type::success);
    auto batch = prompt();
    batch["prompt"] = json::array({"Once", "Twice"});
    batch["n"] = 1;
    full = first->completion(batch)->result();
    assert(full.type == event_type::success && full.data.size() == 2);

    // The first generation cannot finish naturally: EOS is ignored, no token
    // limit. Observing its first payload establishes that it owns the sole slot.
    auto active = first->completion(prompt(true, -1));
    assert(active->next_for(10s).type == event_type::payload);
    auto waiting = first->completion(prompt());
    waiting->cancel();
    assert(terminal(*waiting).type == event_type::cancelled);
    active->cancel();
    assert(terminal(*active).type == event_type::cancelled);
    { auto abandoned = first->completion(prompt(true, -1));
      assert(abandoned->next_for(10s).type == event_type::payload); }
    assert(first->completion(prompt())->result().type == event_type::success);

    config parallel_settings = settings;
    parallel_settings.parallel = 2;
    auto second = create(parallel_settings);
    batch["n"] = 2;
    full = second->completion(batch)->result();
    assert(full.type == event_type::success && full.data.size() == 4);
    active = first->completion(prompt(true, -1));
    assert(active->next_for(10s).type == event_type::payload);
    waiting = first->completion(prompt());
    std::promise<void> entered;
    auto reader = std::async(std::launch::async, [&] { entered.set_value(); return waiting->next(); });
    entered.get_future().wait();
    first->stop();
    assert(reader.wait_for(10s) == std::future_status::ready);
    assert(reader.get().type == event_type::cancelled);
    first.reset();
    assert(waiting->next().type == event_type::cancelled);
    assert(second->completion(prompt())->result().type == event_type::success);
    second->stop();
    assert(second->completion(prompt())->next().category == "stopped");

    config limited_settings = settings;
    limited_settings.max_tasks = 2;
    auto limited = create(limited_settings);
    auto occupied = limited->completion(prompt(true, -1));
    assert(occupied->next_for(10s).type == event_type::payload);
    auto queued = limited->completion(prompt());
    assert(limited->completion(prompt())->result().category == "capacity_exceeded");
    limited->stop();
    assert(terminal(*queued).type == event_type::cancelled);

    settings.max_events = 1;
    auto bounded = create(settings);
    auto slow = bounded->completion(prompt(true, 64));
    // Completing a second request proves the decoder has progressed beyond the
    // saturated first request; no timing/sleep assumption about model speed.
    assert(bounded->completion(prompt())->result().type == event_type::success);
    assert(terminal(*slow).category == "queue_full");
    assert(terminal(*slow).category == "queue_full");
    bounded.reset();

    for (int i = 0; i < 8; ++i) {
        auto owner = create(settings);
        auto req = owner->completion(prompt(true, 1));
        std::promise<void> go;
        auto gate = go.get_future().share();
        auto cancel = std::async(std::launch::async, [&] { gate.wait(); req->cancel(); });
        auto stop = std::async(std::launch::async, [&] { gate.wait(); owner->stop(); });
        go.set_value();
        cancel.get(); stop.get();
        auto end = terminal(*req);
        assert(end.type == event_type::success || end.type == event_type::cancelled || end.category == "queue_full");
        assert(req->next().type == end.type);
    }
    std::cout << "PASS direct CPU completion, streaming, batches, cancellation, stop, saturation, two engines, races\n";
}
