// Exercise the optional acquisition library against a controlled HTTP endpoint.
// No executable argument parser, server-context or subprocess is linked here.
#include "common.h"
#include "download.h"
#include "http.h"
#include "json.h"

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>

namespace fs = std::filesystem;

struct download_observer : common_download_callback {
    bool cancel_on_update = false;
    bool cancelled = false;
    bool started = false;
    bool done = false;
    bool success = false;
    size_t downloaded = 0;

    void on_start(const common_download_progress &) override { started = true; }
    void on_update(const common_download_progress & p) override {
        downloaded = p.downloaded;
        cancelled = cancel_on_update;
    }
    void on_done(const common_download_progress &, bool ok) override {
        done = true;
        success = ok;
    }
    bool is_cancelled() const override { return cancelled; }
};

int main() {
    const auto id = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() / ("test-acquisition-" + std::to_string(id));
    GGML_ASSERT(fs::create_directory(root));
    common_set_env("LLAMA_CACHE", (root / "hub").string());

    const std::string contents(128 * 1024, 'x');
    const std::string commit(40, 'a');
    std::atomic<int32_t> hits{0};
    httplib::Server server;
    server.Get("/file", [&](const httplib::Request &, httplib::Response & res) {
        ++hits;
        res.set_header("ETag", "fixture");
        res.set_content(contents, "application/octet-stream");
    });
    server.Get("/api/models/test/model/refs", [&](const httplib::Request &, httplib::Response & res) {
        res.set_content(common_json{{"branches", common_json::array({common_json{{"name", "main"}, {"targetCommit", commit}}})}}.dump(),
                        "application/json");
    });
    server.Get("/api/models/test/model/tree/" + commit, [&](const httplib::Request &, httplib::Response & res) {
        res.set_content(common_json::array({
            {{"type", "file"}, {"path", "model-Q8_0.gguf"}, {"oid", std::string(40, 'b')}},
            {{"type", "file"}, {"path", "mmproj-F16.gguf"}, {"oid", std::string(40, 'c')}},
            {{"type", "file"}, {"path", "../../escape.gguf"}, {"oid", std::string(40, 'd')}},
            {{"type", "file"}, {"path", "bad-oid.gguf"}, {"oid", "invalid"}},
        }).dump(), "application/json");
    });
    const int port = server.bind_to_any_port("127.0.0.1");
    GGML_ASSERT(port > 0);
    std::thread worker([&] { server.listen_after_bind(); });
    server.wait_until_ready();
    const std::string endpoint = "http://127.0.0.1:" + std::to_string(port);
    common_set_env("MODEL_ENDPOINT", endpoint + "/");

    common_params_model model;
    model.hf_repo = "test/model:Q8_0";
    common_download_opts options;
    options.download_mmproj = true;
    const auto plan = common_download_get_hf_plan(model, options);
    GGML_ASSERT(plan.primary.path == "model-Q8_0.gguf");
    GGML_ASSERT(plan.mmproj.path == "mmproj-F16.gguf");
    GGML_ASSERT(plan.model_files.size() == 1);
    GGML_ASSERT(!fs::exists(root / "escape.gguf"));

    download_observer success;
    options.callback = &success;
    const auto downloaded = (root / "downloaded").string();
    GGML_ASSERT(common_download_file_single(endpoint + "/file", downloaded, options) == 200);
    GGML_ASSERT(success.started && success.done && success.success);
    GGML_ASSERT(success.downloaded == contents.size());
    GGML_ASSERT(fs::file_size(downloaded) == contents.size());
    GGML_ASSERT(!fs::exists(downloaded + ".downloadInProgress"));
    std::ifstream input(downloaded, std::ios::binary);
    const std::string actual((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    GGML_ASSERT(actual == contents);
    input.close();

    download_observer cancelled;
    cancelled.cancel_on_update = true;
    options.callback = &cancelled;
    const auto partial = (root / "cancelled").string();
    GGML_ASSERT(common_download_file_single(endpoint + "/file", partial, options) == -1);
    GGML_ASSERT(cancelled.started && cancelled.done && !cancelled.success);
    GGML_ASSERT(cancelled.cancelled && cancelled.downloaded > 0);
    GGML_ASSERT(!fs::exists(partial));
    GGML_ASSERT(!fs::exists(partial + ".downloadInProgress"));

    const auto absent = (root / "absent").string();
    options.callback = nullptr;
    GGML_ASSERT(common_download_file_single(endpoint + "/missing", absent, options) == 404);
    GGML_ASSERT(!fs::exists(absent));

    // Offline operations must not consult even this controlled endpoint.
    const auto before = hits.load();
    options.offline = true;
    GGML_ASSERT(common_download_file_single(endpoint + "/file", downloaded, options) == 304);
    GGML_ASSERT(common_download_file_single(endpoint + "/file", absent, options) == -1);
    GGML_ASSERT(hits.load() == before);

    server.stop();
    worker.join();
    fs::remove_all(root);
    return 0;
}
