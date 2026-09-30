#ifdef NDEBUG
#undef NDEBUG
#endif
// Catalog sources through the public interface: models directory, cache and INI
// presets with llama-server's priorities, then reloads while models are used or
// awaited. Real GGUF loads on CPU; no network, no process, no port.
#include "llama-engine.h"

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <set>
#include <string>

// the engine reads the cache location from the environment
static void set_env(const char * name, const std::string & value) {
#ifdef _WIN32
    _putenv_s(name, value.c_str());
#else
    setenv(name, value.c_str(), 1);
#endif
}

using namespace llama_engine;
using namespace std::chrono_literals;
namespace fs = std::filesystem;

static void write(const fs::path & path, const std::string & text) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path);
    out << text;
}

static const model_entry * find(const std::vector<model_entry> & models, const std::string & id) {
    for (const auto & m : models) {
        if (m.id == id) { return &m; }
    }
    return nullptr;
}

static std::set<std::string> listing(const fs::path & root) {
    std::set<std::string> out;
    if (fs::exists(root)) {
        for (const auto & e : fs::recursive_directory_iterator(root)) { out.insert(e.path().string()); }
    }
    return out;
}

static event result(engine & e, const std::string & model) {
    return e.submit(operation::completion, {{"model", model}, {"prompt", "Once"}, {"n_predict", 2}})->result();
}

static std::string status(engine & e, const std::string & id) {
    for (const auto & m : e.catalog()) {
        if (m["id"] == id) { return m["status"]; }
    }
    return "";
}

int main(int argc, char ** argv) {
    if (argc != 2 && argc != 3) {
        std::cout << "catalog sources NOT RUN (pass a GGUF model path, optionally a projector)\n";
        return 0;
    }
    const fs::path model = argv[1];
    const fs::path mmproj = argc == 3 ? fs::path(argv[2]) : fs::path();
    const auto id = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() / ("test-engine-sources-" + std::to_string(id));
    const fs::path dir = root / "models";
    const fs::path cache = root / "hub";
    const fs::path ini = root / "presets.ini";

    fs::create_directories(dir / "beta");
    fs::copy_file(model, dir / "alpha.gguf");
    fs::copy_file(model, dir / "beta" / "beta-F32.gguf");
    write(dir / "delta" / "delta-F32.gguf", "listed, never loaded");
    write(dir / "delta" / "mmproj-delta.gguf", "listed, never loaded");
    write(dir / "mmproj-companion.gguf", "a companion file is not a model");
    if (!mmproj.empty()) {
        fs::create_directories(dir / "vision");
        fs::copy_file(model, dir / "vision" / "vision-F32.gguf");
        fs::copy_file(mmproj, dir / "vision" / "mmproj-vision.gguf");
    }
    const std::string commit(40, 'a');
    write(cache / "models--test--tiny" / "refs" / "main", commit);
    fs::create_directories(cache / "models--test--tiny" / "snapshots" / commit);
    fs::copy_file(model, cache / "models--test--tiny" / "snapshots" / commit / "tiny-F32.gguf");
    set_env("LLAMA_CACHE", cache.string()); // before any cache access

    const auto presets = [&](const std::string & alpha_ctx, const std::string & custom_extra) {
        write(ini,
            "[*]\nctx-size = 256\n\n"
            "[alpha]\nalias = al, first\ntemp = 0.5\nctx-size = " + alpha_ctx + "\n\n"
            "[custom]\nmodel = " + model.string() + "\nload-on-startup = true\nstop-timeout = 7\nport = 9999\n"
            "no-warmup = true\n" + custom_extra + "\n"
            "[broken]\nmodel = " + model.string() + "\nctx-size = abc\n\n"
            "[mine]\nhf-repo = test/tiny:F32\noffline = true\ndedup-cache-models = true\n");
    };
    presets("256", "");

    catalog_sources sources;
    sources.cache = true;
    sources.models_dir = dir.string();
    sources.presets = ini.string();
    // seed has no LLAMA_ARG_* variable: options without one are valid everywhere
    sources.options = {{"temp", "0.1"}, {"n-gpu-layers", "0"}, {"seed", "3"}};
    // under everything read for a model, like the environment of the former child processes
    sources.defaults = {{"ctx-size", "999"}, {"top-k", "7"}, {"temp", "0.9"}};

    // reading: priorities, aliases, host options, dedup, per-model errors; nothing written
    const auto before = listing(root);
    std::vector<model_entry> models;
    auto read = read_catalog(sources, models);
    assert(read.type == event_type::success);
    assert(listing(root) == before);
    assert(models.size() == (mmproj.empty() ? 7u : 8u));
    const auto * alpha = find(models, "alpha");
    assert(alpha && alpha->source == "preset" && alpha->aliases == std::vector<std::string>({"al", "first"}));
    assert(alpha->settings.options.at("model") == (dir / "alpha.gguf").string());
    assert(alpha->settings.options.at("ctx-size") == "256");
    assert(alpha->settings.options.at("temperature") == "0.1"); // options apply over every preset (canonical key)
    assert(alpha->settings.options.at("seed") == "3");
    assert(alpha->settings.options.at("top-k") == "7");         // defaults apply under every preset
    assert(alpha->input_modalities == std::vector<std::string>({"text"}));
    const auto * beta = find(models, "beta");
    assert(beta && beta->source == "models_dir" && beta->settings.options.at("model") == (dir / "beta" / "beta-F32.gguf").string());
    assert(beta->settings.options.at("ctx-size") == "256"); // the "*" section is over the defaults
    if (!mmproj.empty()) {
        const auto * vision = find(models, "vision");
        assert(vision && vision->input_modalities == std::vector<std::string>({"text", "image"}));
    }
    const auto * delta = find(models, "delta");
    assert(delta && delta->settings.options.at("mmproj") == (dir / "delta" / "mmproj-delta.gguf").string());
    assert(!find(models, "mmproj-companion"));
    const auto * custom = find(models, "custom");
    assert(custom && custom->load_on_startup && custom->settings.options.at("warmup") == "false");
    assert(custom->host_options.at("stop-timeout") == "7" && custom->host_options.at("port") == "9999");
    assert(!custom->settings.options.count("port"));
    const auto * broken = find(models, "broken");
    assert(broken && broken->error.find("ctx-size") != std::string::npos);
    const auto * cached = find(models, "test/tiny:F32");
    assert(cached && cached->source == "cache" && cached->hidden); // provided by [mine]
    assert(find(models, "mine") && !find(models, "mine")->hidden);

    auto no_cache = sources;
    no_cache.cache = false;
    assert(read_catalog(no_cache, models).type == event_type::success && !find(models, "test/tiny:F32"));

    for (const auto & bad : std::vector<std::map<std::string, std::string>>{{{"alias", "x"}}, {{"models-dir", "/tmp"}}, {{"model", "/m.gguf"}}}) {
        auto s = sources;
        s.options = bad;
        assert(read_catalog(s, models).category == "invalid_config" && models.empty());
        s = sources;
        s.defaults = bad;
        assert(read_catalog(s, models).category == "invalid_config" && models.empty());
    }
    write(root / "conflict.ini", "[gamma]\nmodel = " + model.string() + "\nalias = alpha\n");
    auto conflict = sources;
    conflict.presets = (root / "conflict.ini").string();
    assert(read_catalog(conflict, models).category == "invalid_config");
    conflict.skip_conflicting_aliases = true; // reload behaviour: the alias is dropped
    assert(read_catalog(conflict, models).type == event_type::success && find(models, "gamma")->aliases.empty());
    write(root / "unknown.ini", "[x]\nmodel = /m.gguf\nno-such-option = 1\n");
    auto unknown = sources;
    unknown.presets = (root / "unknown.ini").string();
    assert(read_catalog(unknown, models).category == "invalid_config");

    // an engine over those sources
    assert(read_catalog(sources, models).type == event_type::success);
    catalog_config settings;
    settings.models = models;
    settings.max_loaded = 1;
    event error;
    auto owner = engine::create_catalog(settings, error);
    assert(owner);
    assert(result(*owner, "al").type == event_type::success);          // by alias
    assert(result(*owner, "mine").type == event_type::success);        // hf-repo from the cache
    auto failed = result(*owner, "broken");
    assert(failed.category == "invalid_config" && status(*owner, "broken") == "failed");

    // a changed preset reloads the resident model with its new settings
    assert(result(*owner, "alpha").type == event_type::success && status(*owner, "alpha") == "loaded");
    presets("128", "");
    sources.skip_conflicting_aliases = true;
    assert(read_catalog(sources, models).type == event_type::success);
    assert(owner->update_catalog(models).type == event_type::success);
    assert(status(*owner, "alpha") == "unloading" || status(*owner, "alpha") == "unloaded");
    assert(result(*owner, "first").type == event_type::success);

    // beta removed from its directory while generating; custom changed while waiting
    auto streaming = owner->submit(operation::completion,
        {{"model", "beta"}, {"prompt", "Once"}, {"n_predict", 100000}, {"ignore_eos", true}, {"stream", true}});
    assert(streaming->next_for(30s).type == event_type::payload);
    auto waiting = std::async(std::launch::async, [&] { return result(*owner, "custom"); });
    std::this_thread::sleep_for(50ms);
    assert(status(*owner, "custom") == "unloaded"); // waits for the only slot, held by beta
    fs::remove_all(dir / "beta");
    presets("128", "ctx-size = 192\n");
    assert(read_catalog(sources, models).type == event_type::success && !find(models, "beta"));
    assert(owner->update_catalog(models).type == event_type::success);
    event end;
    do { end = streaming->next_for(30s); } while (end.type == event_type::payload);
    assert(end.category == "unloaded");
    assert(waiting.wait_for(60s) == std::future_status::ready && waiting.get().type == event_type::success);
    assert(result(*owner, "beta").category == "model_not_found");
    assert(status(*owner, "beta").empty());

    // an invalid list leaves the catalog as it was
    auto duplicate = models;
    duplicate.push_back(duplicate.front());
    assert(owner->update_catalog(duplicate).category == "invalid_config");
    assert(result(*owner, "custom").type == event_type::success);

    // cache management is local: removing a cached model needs no network
    assert(owner->remove("custom").category == "invalid_request"); // not from the cache
    assert(result(*owner, "test/tiny:F32").type == event_type::success);
    assert(owner->remove("test/tiny:F32").type == event_type::success);
    assert(status(*owner, "test/tiny:F32").empty());
    assert(!fs::exists(cache / "models--test--tiny" / "snapshots" / commit / "tiny-F32.gguf"));

    event single_error;
    config one;
    one.model_path = model.string();
    auto single = engine::create(one, single_error);
    assert(single && single->update_catalog(models).category == "invalid_request");

    owner.reset();
    single.reset();
    fs::remove_all(root);
    std::cout << "PASS catalog sources, priorities, defaults, modalities, dedup, reloads during use and waiting\n";
}
