#ifdef NDEBUG
#undef NDEBUG
#endif
// Public multi-model consumer with real GGUF loads: no server, port or child
// process. Race-forcing cases live in test-engine-models (controlled backends).
#include "llama-engine.h"
#include <cassert>
#include <filesystem>
#include <future>
#include <iostream>

using namespace llama_engine;
using namespace std::chrono_literals;

static json prompt(const std::string & model, int count = 8, bool stream = false) {
    return {{"model", model}, {"prompt", "Once upon a time"}, {"n_predict", count}, {"stream", stream},
            {"ignore_eos", true}, {"temperature", 0}, {"cache_prompt", false}};
}

static event terminal(request & req) {
    for (;;) {
        auto e = req.next_for(30s);
        assert(e.type != event_type::timeout);
        if (e.terminal()) { return e; }
    }
}

static std::string status(const engine & e, const std::string & id) {
    for (const auto & entry : e.catalog()) {
        if (entry["id"] == id) { return entry["status"]; }
    }
    return "";
}

// Reads events until a status of model reaches want; returns the statuses seen.
static std::vector<std::string> until(subscription & sub, const std::string & model, const std::string & want) {
    std::vector<std::string> seen;
    for (;;) {
        auto e = sub.next_for(30s);
        assert(e.type == event_type::payload);
        if (e.data["type"] == "status" && e.data["model"] == model) {
            seen.push_back(e.data["status"]);
            if (seen.back() == want) { return seen; }
        } else if (e.data["type"] == "progress" && e.data["model"] == model) {
            seen.push_back("progress");
        }
    }
}

static config base(const std::string & path) {
    config c;
    c.model_path = path;
    c.context_size = 512;
    return c;
}

int main(int argc, char ** argv) {
    if (argc != 2) {
        std::cout << "catalog integration NOT RUN (pass a GGUF model path)\n";
        return 0;
    }
    const std::string model = argv[1];
    event error;

    catalog_config invalid;
    invalid.max_waiting = 0;
    assert(!engine::create_catalog(invalid, error) && error.category == "invalid_config");
    // an empty catalog is valid: models may be added by update_catalog
    assert(engine::create_catalog(catalog_config{}, error) && error.category.empty());

    // limit 1: load on demand, evict the idle model, failed load leaves no reservation
    {
        catalog_config settings;
        settings.max_loaded = 1;
        settings.models = {{"a", {"alias-a"}, {"tag"}, base(model)}, {"b", {}, {}, base(model)},
                           {"c", {}, {}, base("/nonexistent/llama-engine-catalog.gguf")}};
        auto e = engine::create_catalog(settings, error);
        assert(e);
        assert(status(*e, "a") == "unloaded" && status(*e, "b") == "unloaded");
        auto sub = e->subscribe();
        assert(sub->next().data["type"] == "snapshot");

        assert(e->submit(operation::completion, prompt("alias-a"))->result().type == event_type::success);
        auto seen = until(*sub, "a", "loaded");
        assert(seen.front() == "unloaded" && seen[1] == "loading" && seen.back() == "loaded");
        assert(std::count(seen.begin(), seen.end(), "progress") >= 2); // first and final sample

        auto chat = e->submit(operation::tokenize, {{"model", "b"}, {"content", "hello"}})->result();
        assert(chat.type == event_type::success && chat.data["tokens"].size() > 0);
        assert(status(*e, "a") == "unloaded" && status(*e, "b") == "loaded");
        until(*sub, "a", "unloaded");

        auto failed = e->submit(operation::completion, prompt("c"))->result();
        assert(failed.type == event_type::error && failed.category == "load_failed");
        assert(status(*e, "c") == "failed");
        assert(e->submit(operation::completion, prompt("a"))->result().type == event_type::success);
        assert(status(*e, "a") == "loaded" && status(*e, "b") == "unloaded");
        assert(e->submit(operation::completion, prompt("zzz"))->result().category == "model_not_found");
        e->stop();
        auto end = sub->next();
        while (end.type == event_type::payload) { end = sub->next(); }
        assert(end.category == "stopped");
    }

    // limit 2: concurrent requests for one model share a single load; two models serve together
    {
        catalog_config settings;
        settings.max_loaded = 2;
        settings.models = {{"a", {}, {}, base(model)}, {"b", {}, {}, base(model)}};
        auto e = engine::create_catalog(settings, error);
        auto sub = e->subscribe();
        std::vector<std::future<event>> results;
        for (int i = 0; i < 8; ++i) {
            results.push_back(std::async(std::launch::async, [&e, i] {
                return e->submit(operation::completion, prompt(i % 4 ? "a" : "b"))->result();
            }));
        }
        for (auto & r : results) { assert(r.get().type == event_type::success); }
        assert(status(*e, "a") == "loaded" && status(*e, "b") == "loaded");
        // status events are also republished when the waiting count changes: count transitions
        int loads_a = 0;
        std::string last = "unloaded";
        for (auto ev = sub->next_for(0ms); ev.type == event_type::payload; ev = sub->next_for(0ms)) {
            if (ev.data["type"] == "status" && ev.data["model"] == "a") {
                loads_a += ev.data["status"] == "loading" && last != "loading";
                last = ev.data["status"];
            }
        }
        assert(loads_a == 1);

        // explicit unload during generation cancels the request, then frees the model
        auto stream = e->submit(operation::completion, prompt("a", 100000, true));
        auto first = stream->next_for(30s);
        assert(first.type == event_type::payload);
        auto unloaded = e->unload("a");
        assert(unloaded.type == event_type::success);
        auto end = terminal(*stream);
        assert(end.type == event_type::cancelled && end.category == "unloaded");
        assert(status(*e, "a") == "unloaded" && status(*e, "b") == "loaded");
        assert(e->unload("a").category == "model_not_loaded");
        assert(e->load("a")->result().type == event_type::success); // explicit load
        assert(status(*e, "a") == "loaded");
        e->stop();
    }

    // sleep and a failed wake-up are explicit and recoverable
    {
        const auto dir = std::filesystem::temp_directory_path() /
            ("test-engine-catalog-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(dir);
        const auto copy = dir / "model.gguf";
        const auto moved = dir / "moved.gguf";
        std::filesystem::copy_file(model, copy);
        catalog_config settings;
        auto sleepy = base(copy.string());
        sleepy.sleep_idle_seconds = 1;
        settings.models = {{"s", {}, {}, sleepy}};
        auto e = engine::create_catalog(settings, error);
        auto sub = e->subscribe();
        assert(e->load("s")->result().type == event_type::success);
        until(*sub, "s", "sleeping");
        auto props = e->submit(operation::properties, {{"model", "s"}})->result(); // no wake-up
        assert(props.type == event_type::success && status(*e, "s") == "sleeping");
        std::filesystem::rename(copy, moved);
        auto failed = e->submit(operation::completion, prompt("s"))->result();
        assert(failed.type == event_type::error && failed.category == "wake_failed");
        assert(status(*e, "s") == "sleeping");
        std::filesystem::rename(moved, copy);
        assert(e->submit(operation::completion, prompt("s"))->result().type == event_type::success);
        assert(status(*e, "s") == "loaded" || status(*e, "s") == "sleeping");
        e->stop();
        std::filesystem::remove_all(dir);
    }

    // single-model engines use the same lifecycle; instances are independent
    {
        auto first = engine::create(base(model), error);
        auto second = engine::create(base(model), error);
        assert(first && second);
        const std::string id = first->catalog()[0]["id"];
        assert(first->catalog()[0]["status"] == "loaded");
        assert(first->unload(id).type == event_type::success);
        assert(first->catalog()[0]["status"] == "unloaded");
        assert(first->completion(prompt("ignored"))->result().type == event_type::success); // reloads
        first->stop();
        assert(second->completion(prompt("ignored"))->result().type == event_type::success);
        second.reset();
    }
    std::cout << "PASS catalog integration\n";
    return 0;
}
