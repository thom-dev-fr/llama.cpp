#ifdef NDEBUG
#undef NDEBUG
#endif
// Network acquisition through the public interface, against a controlled HTTP
// endpoint (no Internet): download with progress, a real load of the result,
// cancellation with cleanup, failure, removal and the catalog around them.
#include "llama-engine.h"
#include "common.h"

#include <cpp-httplib/httplib.h>

#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mutex>
#include <set>
#include <string>
#include <thread>

using namespace llama_engine;
using namespace std::chrono_literals;
namespace fs = std::filesystem;

static std::string status(engine & e, const std::string & id) {
    for (const auto & m : e.catalog()) {
        if (m["id"] == id) { return m["status"]; }
    }
    return "";
}

static bool eventually(const std::function<bool()> & done) {
    for (int i = 0; i < 500 && !done(); ++i) { std::this_thread::sleep_for(10ms); }
    return done();
}

static size_t count_files(const fs::path & root, const std::string & needle) {
    size_t n = 0;
    if (fs::exists(root)) {
        for (const auto & e : fs::recursive_directory_iterator(root)) {
            n += e.path().filename().string().find(needle) != std::string::npos;
        }
    }
    return n;
}

int main(int argc, char ** argv) {
    if (argc != 2) {
        std::cout << "acquisition NOT RUN (pass a GGUF model path)\n";
        return 0;
    }
    std::ifstream in(argv[1], std::ios::binary);
    const std::string gguf((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const auto id = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() / ("test-engine-acquisition-" + std::to_string(id));
    const fs::path cache = root / "hub";
    common_set_env("LLAMA_CACHE", cache.string());

    const std::string commit(40, 'a');
    std::mutex gate_mutex;
    std::condition_variable gate_cv;
    bool gate_open = false;
    std::atomic<int> slow_chunks {0};

    httplib::Server server;
    auto repo = [&](const std::string & name, const std::string & file) {
        server.Get("/api/models/test/" + name + "/refs", [=](const httplib::Request &, httplib::Response & res) {
            res.set_content("{\"branches\":[{\"name\":\"main\",\"targetCommit\":\"" + commit + "\"}]}", "application/json");
        });
        server.Get("/api/models/test/" + name + "/tree/" + commit, [=](const httplib::Request &, httplib::Response & res) {
            res.set_content("[{\"type\":\"file\",\"path\":\"" + file + "\",\"oid\":\"" + std::string(40, 'b') + "\"}]",
                            "application/json");
        });
    };
    repo("model", "model-Q8_0.gguf");
    repo("slow", "slow-Q8_0.gguf");
    repo("broken", "broken-Q8_0.gguf");
    server.Get("/test/model/resolve/" + commit + "/model-Q8_0.gguf", [&](const httplib::Request &, httplib::Response & res) {
        std::unique_lock<std::mutex> lock(gate_mutex);
        gate_cv.wait(lock, [&] { return gate_open; }); // the test observes "downloading" first
        res.set_content(gguf, "application/octet-stream");
    });
    server.Get("/test/slow/resolve/" + commit + "/slow-Q8_0.gguf", [&](const httplib::Request &, httplib::Response & res) {
        res.set_content_provider(gguf.size() * 64, "application/octet-stream",
            [&](size_t offset, size_t, httplib::DataSink & sink) {
                slow_chunks++;
                std::this_thread::sleep_for(20ms);
                const size_t n = std::min<size_t>(4096, gguf.size() * 64 - offset);
                std::string chunk(n, 'x');
                return sink.write(chunk.data(), chunk.size());
            });
    });
    server.Get("/test/broken/resolve/" + commit + "/broken-Q8_0.gguf", [](const httplib::Request &, httplib::Response & res) {
        res.status = 404;
    });
    const int port = server.bind_to_any_port("127.0.0.1");
    assert(port > 0);
    std::thread worker([&] { server.listen_after_bind(); });
    server.wait_until_ready();
    common_set_env("MODEL_ENDPOINT", "http://127.0.0.1:" + std::to_string(port) + "/");

    catalog_config settings;
    settings.sources = catalog_sources{};
    settings.sources->cache = true;
    settings.sources->options = {{"ctx-size", "256"}, {"n-gpu-layers", "0"}, {"fit", "off"}};
    config fixed;
    fixed.model_path = argv[1];
    settings.models = {model_entry("local", {}, {}, fixed)};
    event error;
    auto owner = engine::create_catalog(settings, error);
    assert(owner && owner->catalog().size() == 1);
    auto sub = owner->subscribe();

    // download: listed as downloading, not usable meanwhile, then read from the cache
    const std::string name = "test/model:Q8_0";
    auto download = owner->download(name);
    assert(status(*owner, name) == "downloading");
    auto busy = owner->submit(operation::completion, {{"model", name}, {"prompt", "x"}})->result();
    assert(busy.category == "model_downloading");
    assert(owner->download(name)->result().message.find("already exists") != std::string::npos);
    {
        std::lock_guard<std::mutex> lock(gate_mutex);
        gate_open = true;
        gate_cv.notify_all();
    }
    auto done = download->result();
    assert(done.type == event_type::success && done.data["model"] == name);
    assert(status(*owner, name) == "unloaded"); // read again from the cache (source "cache")
    bool saw_downloading = false, saw_progress = false, saw_finished = false, saw_reload = false;
    for (auto item = sub->next_for(1s); item.type == event_type::payload; item = sub->next_for(100ms)) {
        const auto & d = item.data;
        saw_downloading |= d["type"] == "status" && d["status"] == "downloading";
        saw_progress    |= d["type"] == "progress" && d["progress"]["stage"] == "download";
        saw_finished    |= d["type"] == "download" && d["result"] == "finished";
        saw_reload      |= d["type"] == "reload";
    }
    assert(saw_downloading && saw_progress && saw_finished && saw_reload);
    auto generated = owner->submit(operation::completion, {{"model", name}, {"prompt", "Once"}, {"n_predict", 2}})->result();
    assert(generated.type == event_type::success);
    assert(count_files(cache, "model-Q8_0.gguf") == 1);

    // removal while resident: unloaded, files and entry gone; other sources are not removable
    assert(status(*owner, name) == "loaded");
    auto removed = owner->remove(name);
    assert(removed.type == event_type::success && removed.data["removed_files"] == true);
    assert(status(*owner, name).empty() && count_files(cache, "model-Q8_0") == 0);
    assert(owner->remove("local").category == "invalid_request");
    assert(owner->remove(name).category == "model_not_found");

    // cancellation: the placeholder leaves and no incomplete file remains
    auto slow = owner->download("test/slow:Q8_0");
    assert(eventually([&] { return slow_chunks.load() > 2; }));
    slow->cancel();
    assert(slow->result().type == event_type::cancelled);
    assert(eventually([&] { return status(*owner, "test/slow:Q8_0").empty(); }));
    assert(count_files(cache, "slow-Q8_0") == 0 && count_files(cache, "downloadInProgress") == 0);
    // unloading a model being downloaded also cancels it, as llama-server does
    auto again = owner->download("test/slow:Q8_0");
    assert(eventually([&] { return status(*owner, "test/slow:Q8_0") == "downloading"; }));
    assert(owner->unload("test/slow:Q8_0").type == event_type::success);
    assert(again->result().type == event_type::cancelled && status(*owner, "test/slow:Q8_0").empty());

    // failure: explicit error, no entry left behind
    auto broken = owner->download("test/broken:Q8_0")->result();
    assert(broken.category == "download_failed" && broken.message.find("404") != std::string::npos);
    assert(status(*owner, "test/broken:Q8_0").empty() && count_files(cache, "broken-Q8_0") == 0);

    // stop during a download ends it
    auto pending = owner->download("test/slow:Q8_0");
    assert(eventually([&] { return status(*owner, "test/slow:Q8_0") == "downloading"; }));
    owner->stop();
    assert(pending->result().type == event_type::cancelled);
    owner.reset();

    server.stop();
    worker.join();
    fs::remove_all(root);
    std::cout << "PASS acquisition: download, progress, load, cancel, failure, removal\n";
}
