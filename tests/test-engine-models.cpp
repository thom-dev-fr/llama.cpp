#ifdef NDEBUG
#undef NDEBUG
#endif
// Model lifecycle policy with controlled backends: loads block until released,
// fail or get cancelled on demand, and requests stay active until finished by
// the test. No model, process or port; no timing assumption about inference.
#include "engine-models.h"
#include <cassert>
#include <future>
using namespace llama_engine;
using namespace llama_engine::detail;
using namespace std::chrono_literals;

struct world {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::string> log;                 // load:X, loaded:X, stop:X
    std::map<std::string, int> loads;
    std::set<std::string> blocked, failing, released;
    std::map<std::string, std::vector<std::shared_ptr<request_state>>> active;
    std::map<std::string, backend_hooks> hooks;

    void record(const std::string & line) {
        std::lock_guard<std::mutex> lock(mutex);
        log.push_back(line);
        changed.notify_all();
    }
    bool wait_for(const std::function<bool()> & done) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, 5s, done);
    }
    void set(std::set<std::string> & field, std::set<std::string> values) {
        std::lock_guard<std::mutex> lock(mutex);
        field = std::move(values);
        changed.notify_all();
    }
    void release(const std::string & model) {
        std::lock_guard<std::mutex> lock(mutex);
        released.insert(model);
        changed.notify_all();
    }
    // finish the oldest active request of a model
    void finish(const std::string & model) {
        std::shared_ptr<request_state> state;
        {
            std::unique_lock<std::mutex> lock(mutex);
            assert(changed.wait_for(lock, 5s, [&] { return !active[model].empty(); }));
            state = active[model].front();
            active[model].erase(active[model].begin());
        }
        state->finish({event_type::success, nullptr, {}, {}});
    }
    size_t n(const std::string & line) const { // caller holds mutex (wait_for predicates)
        return std::count(log.begin(), log.end(), line);
    }
    size_t count(const std::string & line) {
        std::lock_guard<std::mutex> lock(mutex);
        return n(line);
    }
};

struct fake_backend : model_backend {
    world & w;
    std::string id;
    std::atomic<bool> cancelled {false};
    fake_backend(world & w, std::string id) : w(w), id(std::move(id)) {}

    bool load(std::string & error) override {
        {
            std::unique_lock<std::mutex> lock(w.mutex);
            w.loads[id]++;
            w.log.push_back("load:" + id);
            w.changed.notify_all();
            w.changed.wait(lock, [&] { return !w.blocked.count(id) || w.released.count(id) || cancelled; });
            w.released.erase(id);
            auto hooks = w.hooks[id];
            const bool failing = w.failing.count(id) > 0;
            lock.unlock();
            if (hooks.progress) { hooks.progress(::json {{"value", 0.5}}); }
            if (cancelled) { error = "cancelled"; return false; }
            if (failing) { error = "boom " + id; return false; }
        }
        w.record("loaded:" + id);
        return true;
    }
    void cancel_load() override {
        cancelled = true;
        std::lock_guard<std::mutex> lock(w.mutex);
        w.changed.notify_all();
    }
    void submit(const std::shared_ptr<request_state> & state, const ::json &, operation,
                const std::vector<attachment> &) override {
        std::lock_guard<std::mutex> lock(w.mutex);
        w.active[id].push_back(state);
        w.log.push_back("submit:" + id);
        w.changed.notify_all();
    }
    void stop(const event & reason) override {
        std::vector<std::shared_ptr<request_state>> states;
        {
            std::unique_lock<std::mutex> lock(w.mutex);
            w.log.push_back("stopping:" + id);
            w.changed.notify_all();
            w.changed.wait(lock, [&] { return !w.blocked.count("stop:" + id) || w.released.count("stop:" + id); });
            w.released.erase("stop:" + id);
            states.swap(w.active[id]);
            w.log.push_back("stop:" + id);
            w.changed.notify_all();
        }
        for (auto & state : states) { state->finish(reason); }
    }
};

static std::shared_ptr<model_manager> make(world & w, int max_loaded, std::vector<std::string> ids,
                                           std::chrono::milliseconds timeout = 10s, size_t max_waiting = 64,
                                           bool autoload = true) {
    catalog_config settings;
    for (auto & id : ids) {
        model_entry entry;
        entry.id = id;
        entry.aliases = {id + "-alias"};
        entry.settings.model_path = "/fake/" + id + ".gguf";
        settings.models.push_back(entry);
    }
    settings.max_loaded = max_loaded;
    settings.wait_timeout = timeout;
    settings.max_waiting = max_waiting;
    settings.autoload = autoload;
    settings.max_subscriber_events = 4;
    std::string error;
    assert(model_manager::validate(settings, error));
    auto manager = std::make_shared<model_manager>(settings, false, [&w](const model_entry & entry, backend_hooks hooks) {
        {
            std::lock_guard<std::mutex> lock(w.mutex);
            w.hooks[entry.id] = hooks;
        }
        return std::make_shared<fake_backend>(w, entry.id);
    });
    manager->start();
    return manager;
}

static llama_engine::json req(const std::string & model) { return {{"model", model}, {"prompt", "x"}}; }

static std::string status(model_manager & m, const std::string & id) {
    for (const auto & entry : m.catalog()) {
        if (entry["id"] == id) { return entry["status"]; }
    }
    return "";
}

static event wait_terminal(const std::shared_ptr<request_state> & state) {
    auto reader = std::async(std::launch::async, [state] {
        for (;;) {
            auto item = state->read(std::chrono::milliseconds::max());
            if (item.terminal()) { return item; }
        }
    });
    assert(reader.wait_for(5s) == std::future_status::ready);
    return reader.get();
}

int main() {
    // configuration: aliases may not shadow names
    {
        catalog_config bad;
        bad.models = {{"a", {"b"}, {}, {}}, {"b", {}, {}, {}}};
        bad.models[0].settings.model_path = bad.models[1].settings.model_path = "/m.gguf";
        std::string error;
        assert(!model_manager::validate(bad, error) && error.find("conflicts") != std::string::npos);
    }

    // selection errors, alias resolution, autoload off
    {
        world w;
        auto m = make(w, 1, {"a"}, 10s, 64, false);
        assert(wait_terminal(m->submit(operation::completion, {{"prompt", "x"}}, {})).category == "invalid_request");
        assert(wait_terminal(m->submit(operation::completion, req("zzz"), {})).category == "model_not_found");
        assert(wait_terminal(m->submit(operation::completion, req("a-alias"), {})).category == "model_not_loaded");
        assert(m->unload("a").category == "model_not_loaded");
        assert(wait_terminal(m->load("a-alias")).type == event_type::success);
        assert(status(*m, "a") == "loaded");
        auto r = m->submit(operation::completion, req("a-alias"), {});
        w.finish("a");
        assert(wait_terminal(r).type == event_type::success);
        m->stop();
    }

    // limit 1: A busy, B waits; A finishes, A is evicted, then B loads
    {
        world w;
        auto m = make(w, 1, {"a", "b"});
        auto ra = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 1; }));
        auto rb = m->submit(operation::completion, req("b"), {});
        std::this_thread::sleep_for(50ms); // give a wrong implementation the chance to evict a busy model
        assert(w.count("stop:a") == 0 && w.count("load:b") == 0);
        assert(status(*m, "b") == "unloaded" && m->catalog()[1]["waiting"] == 1);
        w.finish("a");
        assert(wait_terminal(ra).type == event_type::success);
        assert(w.wait_for([&] { return w.n("submit:b") == 1; }));
        {
            std::lock_guard<std::mutex> lock(w.mutex);
            auto stop_a = std::find(w.log.begin(), w.log.end(), "stop:a");
            auto load_b = std::find(w.log.begin(), w.log.end(), "load:b");
            assert(stop_a != w.log.end() && stop_a < load_b); // freed before the next load
        }
        assert(status(*m, "a") == "unloaded" && status(*m, "b") == "loaded");
        w.finish("b");
        assert(wait_terminal(rb).type == event_type::success);

        // cancellation and expiry while waiting release the queue entry
        auto busy = m->submit(operation::completion, req("b"), {});
        assert(w.wait_for([&] { return w.n("submit:b") == 2; }));
        auto cancelled = m->submit(operation::completion, req("a"), {});
        request(cancelled).cancel();
        assert(wait_terminal(cancelled).type == event_type::cancelled);
        assert(m->catalog()[0]["waiting"] == 0);
        w.finish("b");
        assert(wait_terminal(busy).type == event_type::success);
        std::this_thread::sleep_for(50ms);
        assert(w.count("load:a") == 1 && status(*m, "b") == "loaded"); // no load for a cancelled waiter
        m->stop();
    }

    // bounded wait: a model kept busy makes the waiter fail explicitly, never silently
    {
        world w;
        auto m = make(w, 1, {"a", "b"}, 200ms);
        auto ra = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 1; }));
        auto rb = m->submit(operation::completion, req("b"), {});
        auto end = wait_terminal(rb);
        assert(end.type == event_type::error && end.category == "wait_timeout");
        assert(m->catalog()[1]["waiting"] == 0 && w.count("load:b") == 0);
        w.finish("a");
        assert(wait_terminal(ra).type == event_type::success);
        m->stop();
    }

    // service order is first come, first served; bounded number of waiters
    {
        world w;
        auto m = make(w, 1, {"a", "b", "c"}, 10s, 4);
        auto ra = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 1; }));
        auto rb = m->submit(operation::completion, req("b"), {});
        auto rc = m->submit(operation::completion, req("c"), {});
        auto rb2 = m->submit(operation::completion, req("b"), {}); // joins b's entry
        auto rl = m->load("c");
        auto overflow = m->submit(operation::completion, req("c"), {});
        assert(wait_terminal(overflow).category == "capacity_exceeded");
        w.finish("a");
        assert(w.wait_for([&] { return w.n("submit:b") == 2; }));
        assert(w.count("load:c") == 0);
        w.finish("b");
        std::this_thread::sleep_for(20ms);
        assert(w.count("load:c") == 0); // b is still busy with its second request
        w.finish("b");
        assert(w.wait_for([&] { return w.n("submit:c") == 1; }));
        assert(wait_terminal(rl).type == event_type::success);
        {
            std::lock_guard<std::mutex> lock(w.mutex);
            std::vector<std::string> loads;
            for (auto & line : w.log) { if (line.rfind("load:", 0) == 0) { loads.push_back(line); } }
            assert((loads == std::vector<std::string>{"load:a", "load:b", "load:c"}));
        }
        w.finish("c");
        for (auto * r : {&ra, &rb, &rb2, &rc}) { assert(wait_terminal(*r).type == event_type::success); }
        m->stop();
    }

    // limit 2: concurrent requests share one load; a failed load leaves no reservation
    {
        world w;
        w.set(w.blocked, {"a"});
        w.set(w.failing, {"c"});
        auto m = make(w, 2, {"a", "b", "c", "d"});
        std::vector<std::future<std::shared_ptr<request_state>>> same;
        for (int i = 0; i < 8; ++i) {
            same.push_back(std::async(std::launch::async, [&] { return m->submit(operation::completion, req("a"), {}); }));
        }
        std::vector<std::shared_ptr<request_state>> states;
        for (auto & f : same) { states.push_back(f.get()); }
        assert(w.wait_for([&] { return w.loads["a"] == 1; }));
        assert(status(*m, "a") == "loading" && m->catalog()[0]["waiting"] == 8);
        w.release("a");
        assert(w.wait_for([&] { return w.n("submit:a") == 8; }));
        assert(w.loads["a"] == 1);
        auto rc = m->submit(operation::completion, req("c"), {});
        auto end = wait_terminal(rc);
        assert(end.category == "load_failed" && end.message == "boom c");
        assert(status(*m, "c") == "failed");
        auto rb = m->submit(operation::completion, req("b"), {}); // second slot still free
        assert(w.wait_for([&] { return w.n("submit:b") == 1; }));
        assert(status(*m, "a") == "loaded" && status(*m, "b") == "loaded");
        auto rd = m->submit(operation::completion, req("d"), {}); // both busy: waits
        std::this_thread::sleep_for(20ms);
        assert(w.count("load:d") == 0);
        w.finish("b");
        assert(w.wait_for([&] { return w.n("submit:d") == 1; }));
        assert(status(*m, "b") == "unloaded" && w.loads["c"] == 1);
        for (int i = 0; i < 8; ++i) { w.finish("a"); }
        w.finish("d");
        for (auto & s : states) { assert(wait_terminal(s).type == event_type::success); }
        assert(wait_terminal(rb).type == event_type::success && wait_terminal(rd).type == event_type::success);
        w.set(w.failing, {});
        assert(wait_terminal(m->load("c")).type == event_type::success); // failure is recoverable
        m->stop();
    }

    // explicit unload during generation and during loading
    {
        world w;
        auto m = make(w, 2, {"a", "b"});
        auto ra = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 1; }));
        auto unloaded = m->unload("a");
        assert(unloaded.type == event_type::success);
        auto end = wait_terminal(ra);
        assert(end.type == event_type::cancelled && end.category == "unloaded");
        assert(status(*m, "a") == "unloaded" && w.count("stop:a") == 1);

        w.set(w.blocked, {"b"});
        auto rb = m->submit(operation::completion, req("b"), {});
        assert(w.wait_for([&] { return w.loads["b"] == 1; }));
        auto unloading = std::async(std::launch::async, [&] { return m->unload("b"); });
        assert(unloading.wait_for(5s) == std::future_status::ready);
        assert(unloading.get().type == event_type::success);
        end = wait_terminal(rb);
        assert(end.type == event_type::cancelled && end.category == "unloaded");
        assert(status(*m, "b") == "unloaded" && w.count("submit:b") == 0);

        // a request arriving during an unload waits for the next instance
        w.set(w.blocked, {"stop:a"});
        auto first = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 2; }));
        auto unloader = std::async(std::launch::async, [&] { return m->unload("a"); });
        assert(w.wait_for([&] { return w.n("stopping:a") == 2; }));
        assert(status(*m, "a") == "unloading");
        auto next = m->submit(operation::completion, req("a"), {}); // admissions are closed
        assert(m->catalog()[0]["waiting"] == 1);
        w.release("stop:a");
        assert(unloader.get().type == event_type::success);
        assert(wait_terminal(first).category == "unloaded");
        assert(w.wait_for([&] { return w.n("submit:a") == 3; })); // reloaded for the waiter
        w.set(w.blocked, {});
        w.finish("a");
        assert(wait_terminal(next).type == event_type::success);
        auto after = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 4; }));
        w.finish("a");
        assert(wait_terminal(after).type == event_type::success);
        m->stop();
    }

    // sleeping models stay resident for the policy and take requests directly
    {
        world w;
        auto m = make(w, 1, {"a"});
        assert(wait_terminal(m->load("a")).type == event_type::success);
        backend_hooks hooks;
        {
            std::lock_guard<std::mutex> lock(w.mutex);
            hooks = w.hooks["a"];
        }
        hooks.sleeping(true);
        assert(status(*m, "a") == "sleeping");
        auto r = m->submit(operation::completion, req("a"), {});
        assert(w.wait_for([&] { return w.n("submit:a") == 1; }));
        hooks.sleeping(false);
        assert(status(*m, "a") == "loaded");
        w.finish("a");
        assert(wait_terminal(r).type == event_type::success);
        m->stop();
    }

    // subscriptions: snapshot, ordered state/progress, resync of slow readers, close on stop
    {
        world w;
        auto m = make(w, 1, {"a"});
        auto sub = m->subscribe();
        auto first = sub->read(1s);
        assert(first.data["type"] == "snapshot" && first.data["models"][0]["status"] == "unloaded");
        assert(wait_terminal(m->load("a")).type == event_type::success);
        std::vector<std::string> seen;
        for (auto item = sub->read(1s); item.type == event_type::payload; item = sub->read(50ms)) {
            seen.push_back(item.data["type"] == "status" ? item.data["status"].get<std::string>() : "progress");
        }
        assert((seen == std::vector<std::string>{"unloaded", "loading", "progress", "loaded"}));

        auto slow = m->subscribe(); // capacity 4, never read while 6 events are produced
        for (int i = 0; i < 3; ++i) {
            assert(m->unload("a").type == event_type::success);
            assert(wait_terminal(m->load("a")).type == event_type::success);
        }
        auto resync = slow->read(1s);
        assert(resync.data["type"] == "resync");
        std::string last = resync.data["models"][0]["status"];
        for (auto item = slow->read(0ms); item.type == event_type::payload; item = slow->read(0ms)) {
            if (item.data["type"] == "status") { last = item.data["status"]; }
            if (item.data["type"] == "resync") { last = item.data["models"][0]["status"]; }
        }
        assert(last == "loaded");

        // unsubscribing never cancels a load
        assert(m->unload("a").type == event_type::success);
        w.set(w.blocked, {"a"});
        auto loading = m->load("a");
        {
            auto gone = m->subscribe();
        }
        request(loading).cancel(); // cancelling the waiter does not stop the started load either
        w.release("a");
        assert(w.wait_for([&] { return w.n("loaded:a") == 5; }));
        std::this_thread::sleep_for(20ms);
        assert(status(*m, "a") == "loaded");
        m->stop();
        auto closed = sub->read(std::chrono::milliseconds::max());
        while (closed.type == event_type::payload) { closed = sub->read(std::chrono::milliseconds::max()); }
        assert(closed.type == event_type::cancelled && closed.category == "stopped");
        assert(m->subscribe()->read(0ms).category == "stopped");
    }

    // stop: waiters, blocked loads and active requests all end; independent instances
    for (int round = 0; round < 50; ++round) {
        world w1, w2;
        w1.set(w1.blocked, {"b"});
        auto m1 = make(w1, 1, {"a", "b"});
        auto m2 = make(w2, 1, {"a"});
        auto r2 = m2->submit(operation::completion, req("a"), {});
        auto ra = m1->submit(operation::completion, req("a"), {});
        auto rb = m1->submit(operation::completion, req("b"), {}); // waits: a is busy
        auto racing = std::async(std::launch::async, [&] {
            for (int i = 0; i < 20; ++i) {
                auto r = m1->submit(operation::completion, req(i % 2 ? "a" : "b"), {});
                if (i % 3 == 0) { request(r).cancel(); }
            }
        });
        auto unloading = std::async(std::launch::async, [&] { return m1->unload("a"); });
        m1->stop();
        racing.get();
        (void) unloading.get();
        for (auto & s : {ra, rb}) { assert(wait_terminal(s).terminal()); }
        assert(m1->submit(operation::completion, req("a"), {})->terminal.category == "stopped");
        assert(w2.wait_for([&] { return w2.n("submit:a") == 1; }));
        w2.finish("a");
        assert(wait_terminal(r2).type == event_type::success); // the other instance is unaffected
        m2->stop();
    }
    return 0;
}
