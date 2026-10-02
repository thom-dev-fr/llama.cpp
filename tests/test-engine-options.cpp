#ifdef NDEBUG
#undef NDEBUG
#endif
// Model configuration: every registry option has an owner, named options follow
// the command line exactly, and remote resources resolve locally without HTTP.
#include "llama-engine.h"
#include "engine-options.h"

#include "arg.h"
#include "common.h"
#include "download.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <set>
#include <string>
#include <vector>

using namespace llama_engine;
using llama_engine::detail::build_params;
using llama_engine::detail::option_key;
namespace fs = std::filesystem;

static std::string invalid(const config & settings) {
    try {
        build_params(settings);
    } catch (const std::invalid_argument & e) {
        return e.what();
    }
    return {};
}

static void audit_registry() {
    std::set<std::string> keys;
    for (auto ex : {LLAMA_EXAMPLE_SERVER, LLAMA_EXAMPLE_CLI}) {
        common_params params;
        auto ctx = common_params_parser_init(params, ex);
        common_params_add_preset_options(ctx.options);
        for (const auto & opt : ctx.options) {
            const auto key = option_key(opt);
            if (find_option_scope(key) == option_scope::unknown) {
                std::cerr << "unclassified option: " << key << "\n";
                assert(false);
            }
            keys.insert(key);
        }
    }
    // no stale entry: a removed option must leave the table too
    for (const auto * key : {"ctx-size", "port", "alias", "hf-repo", "stop-timeout", "prompt"}) {
        assert(keys.count(key));
    }
    assert(find_option_scope("ctx-size") == option_scope::engine);
    assert(find_option_scope("hf-repo") == option_scope::engine);
    assert(find_option_scope("port") == option_scope::host);
    assert(find_option_scope("prio") == option_scope::host);
    assert(find_option_scope("models-dir") == option_scope::catalog);
    // other spellings of config::options: dashes, negated form, variable
    assert(find_option_scope("--ctx-size") == option_scope::engine);
    assert(find_option_scope("no-warmup") == option_scope::engine);
    assert(find_option_scope("LLAMA_ARG_CTX_SIZE") == option_scope::engine);
    assert(find_option_scope("LLAMA_ARG_PORT") == option_scope::host);
    assert(find_option_scope("not-an-option") == option_scope::unknown);
}

static void rejections() {
    auto base = config::from_options({{"model", "/m.gguf"}});
    assert(invalid(base).empty());
    auto with = [&](std::map<std::string, std::string> extra) {
        auto c = base;
        for (auto & [k, v] : extra) { c.options[k] = v; }
        return invalid(c);
    };
    assert(with({{"port", "8081"}}).find("host application") != std::string::npos);
    assert(with({{"alias", "x"}}).find("catalog") != std::string::npos);
    assert(with({{"models-dir", "/tmp"}}).find("catalog") != std::string::npos);
    assert(with({{"no-such-option", "1"}}).find("not recognized") != std::string::npos);
    assert(with({{"ctx-size", "abc"}}).find("ctx-size") != std::string::npos);
    assert(with({{"sleep-idle-seconds", "0"}}).find("sleep-idle-seconds") != std::string::npos);
    assert(invalid(config::from_options({})).find("no model") != std::string::npos);

    config typed;
    typed.model_path = "/m.gguf";
    assert(invalid(typed).empty());
    typed.options["ctx-size"] = "1024";
    assert(invalid(typed).find("config::context_size") != std::string::npos);
    typed.options = {{"LLAMA_ARG_CTX_SIZE", "1024"}};
    assert(invalid(typed).find("config::context_size") != std::string::npos);
    typed.context_size = std::nullopt; // the option is then the only source
    assert(invalid(typed).empty() && build_params(typed).n_ctx == 1024);

    event error;
    auto rejected = engine::create(config::from_options({{"model", "/m.gguf"}, {"api-key", "k"}}), error);
    assert(!rejected && error.category == "invalid_config" && error.message.find("api-key") != std::string::npos);
}

static void typed_defaults() {
    config typed;
    typed.model_path = "/m.gguf";
    auto p = build_params(typed);
    assert(p.n_ctx == 512 && p.n_parallel == 1 && p.cpuparams.n_threads == 2 && p.cpuparams_batch.n_threads == 2);
    assert(p.n_gpu_layers == 0 && !p.mmproj_use_gpu && !p.fit_params && !p.warmup);
    assert(p.n_batch == 128 && p.n_ubatch == 128);
    // server post-processing applies to both paths
    assert(p.model_alias.count("/m.gguf") && p.default_template_kwargs.count("preserve_reasoning"));

    typed.embeddings = true;
    typed.pooling_type = 4;
    typed.lora_paths = {"/a,b.gguf", "/c.gguf"};
    typed.gpu_layers = 99;
    p = build_params(typed);
    assert(p.embedding && p.pooling_type == LLAMA_POOLING_TYPE_RANK && p.mmproj_use_gpu);
    assert(p.lora_adapters.size() == 2 && p.lora_adapters[0].path == "/a,b.gguf");

    auto plain = build_params(config::from_options({{"model", "/m.gguf"}}));
    assert(plain.n_ctx == 0 && plain.fit_params && plain.warmup && plain.mmproj_use_gpu);
    assert(plain.n_parallel == 4 && plain.kv_unified); // automatic slots, as llama-server
}

#ifdef LLAMA_TEST_ARGV_PARITY
// Named options must configure a model exactly like the command line of a
// llama-server started with them (as the router starts its children).
static void argv_parity() {
    const std::vector<std::vector<std::string>> cases = {
        {"--model", "/m.gguf"},
        {"-m", "/m.gguf", "-c", "0", "-np", "3", "--fit", "off", "--no-warmup", "-t", "3", "-tb", "5"},
        {"-m", "/m.gguf", "--temp", "0.2", "--top-k", "7", "--seed", "11", "-fa", "on", "-ctk", "q8_0",
         "--jinja", "--reasoning-format", "none", "--chat-template", "chatml", "--no-context-shift"},
        {"-m", "/m.gguf", "--embeddings", "--pooling", "mean", "-b", "512", "-ub", "256", "--kv-unified-per-slot", "64"},
        {"-m", "/m.gguf", "-r", "User:\\n", "--dry-sequence-breaker", "\\n", "--override-kv", "a.b=int:1",
         "--lora", "/l.gguf", "--spec-type", "ngram-simple", "--spec-draft-n-max", "9", "--sleep-idle-seconds", "5"},
        {"-hf", "org/repo:Q4_K_M", "--hf-token", "t", "--offline", "--cache-reuse", "32", "--n-predict", "17"},
    };
    for (const auto & args : cases) {
        std::vector<char *> argv = {const_cast<char *>("llama-server")};
        std::map<std::string, std::string> options;
        for (const auto & a : args) { argv.push_back(const_cast<char *>(a.c_str())); }
        common_params expected;
        assert(common_params_parse((int) argv.size(), argv.data(), expected, LLAMA_EXAMPLE_SERVER));
        llama_engine::detail::apply_server_defaults(expected, true);

        std::map<common_arg, std::string> parsed;
        assert(common_params_to_map((int) argv.size(), argv.data(), LLAMA_EXAMPLE_SERVER, parsed));
        for (const auto & [opt, value] : parsed) { options[option_key(opt)] = value; }
        const auto got = build_params(config::from_options(options));

        assert(got.model.path == expected.model.path && got.model.hf_repo == expected.model.hf_repo);
        assert(got.hf_token == expected.hf_token && got.offline == expected.offline);
        assert(got.n_ctx == expected.n_ctx && got.n_parallel == expected.n_parallel && got.kv_unified == expected.kv_unified);
        assert(got.fit_params == expected.fit_params && got.fit_params_min_ctx == expected.fit_params_min_ctx);
        assert(got.warmup == expected.warmup && got.n_batch == expected.n_batch && got.n_ubatch == expected.n_ubatch);
        assert(got.cpuparams.n_threads == expected.cpuparams.n_threads);
        assert(got.cpuparams_batch.n_threads == expected.cpuparams_batch.n_threads);
        assert(got.n_gpu_layers == expected.n_gpu_layers && got.mmproj_use_gpu == expected.mmproj_use_gpu);
        assert(got.sampling.temp == expected.sampling.temp && got.sampling.top_k == expected.sampling.top_k);
        assert(got.sampling.seed == expected.sampling.seed);
        assert(got.sampling.user_sampling_config == expected.sampling.user_sampling_config);
        assert(got.sampling.dry_sequence_breakers == expected.sampling.dry_sequence_breakers);
        assert(got.flash_attn_type == expected.flash_attn_type && got.cache_type_k == expected.cache_type_k);
        assert(got.use_jinja == expected.use_jinja && got.reasoning_format == expected.reasoning_format);
        assert(got.chat_template == expected.chat_template && got.ctx_shift == expected.ctx_shift);
        assert(got.default_template_kwargs == expected.default_template_kwargs);
        assert(got.embedding == expected.embedding && got.pooling_type == expected.pooling_type);
        assert(got.kv_unified_per_slot == expected.kv_unified_per_slot);
        assert(got.antiprompt == expected.antiprompt && got.kv_overrides.size() == expected.kv_overrides.size());
        assert(got.tensor_buft_overrides.size() == expected.tensor_buft_overrides.size());
        assert(got.lora_adapters.size() == expected.lora_adapters.size());
        assert(got.speculative.types == expected.speculative.types);
        assert(got.speculative.draft.n_max == expected.speculative.draft.n_max);
        assert(got.sleep_idle_seconds == expected.sleep_idle_seconds && got.n_cache_reuse == expected.n_cache_reuse);
        assert(got.n_predict == expected.n_predict && got.model_alias == expected.model_alias);
    }
}
#endif

// A hf-repo already in the cache is a local resource: it loads without HTTP.
// Without network acquisition, a missing one is an explicit capability error.
static void local_resolution(const char * model) {
    const auto id = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() / ("test-engine-options-" + std::to_string(id));
    const std::string commit(40, 'a');
    const fs::path snapshot = root / "models--test--tiny" / "snapshots" / commit;
    fs::create_directories(snapshot);
    fs::create_directories(root / "models--test--tiny" / "refs");
    { FILE * f = fopen((root / "models--test--tiny" / "refs" / "main").string().c_str(), "w"); fputs(commit.c_str(), f); fclose(f); }
    fs::copy_file(model, snapshot / "tiny-F32.gguf");
    common_set_env("LLAMA_CACHE", root.string()); // before any cache access

    const bool network = llama_engine::detail::has_acquisition();
    auto cached = config::from_options({{"hf-repo", "test/tiny"}, {"ctx-size", "256"}, {"offline", "true"}});
    std::vector<config> variants = {cached};
    if (!network) {
        cached.options.erase("offline"); // no transport: the cache is the only source anyway
        variants.push_back(cached);
    }
    for (const auto & settings : variants) {
        event error;
        auto owner = engine::create(settings, error);
        assert(owner);
        auto done = owner->submit(operation::completion, {{"prompt", "Once"}, {"n_predict", 2}})->result();
        assert(done.type == event_type::success);
        assert(owner->catalog()[0]["id"] == "test/tiny");
    }

    if (!network) {
        event error;
        auto absent = engine::create(config::from_options({{"hf-repo", "test/absent"}}), error);
        assert(!absent && error.category == "capability_unavailable");
        assert(error.message.find("network acquisition") != std::string::npos);
        auto remote = engine::create(config::from_options({{"model-url", "https://example.invalid/m-00001-of-00002.gguf"}}), error);
        assert(!remote && error.category == "capability_unavailable");
        auto catalog = engine::create_catalog(catalog_config{}, error);
        auto download = catalog->download("test/absent")->result();
        assert(download.category == "capability_unavailable");
    }
    fs::remove_all(root);
}

// file names are UTF-8 on every platform, as the paths in config
static void utf8_ids() {
    config settings;
    settings.model_path = "/models/mod\xc3\xa8le-\xc3\xbc.gguf";
    assert(model_id(settings) == "mod\xc3\xa8le-\xc3\xbc.gguf");
    assert(model_id(config::from_options({{"model", "/models/\xe6\xa8\xa1\xe5\x9e\x8b.gguf"}})) == "\xe6\xa8\xa1\xe5\x9e\x8b.gguf");
}

int main(int argc, char ** argv) {
    audit_registry();
    utf8_ids();
    rejections();
    typed_defaults();
#ifdef LLAMA_TEST_ARGV_PARITY
    argv_parity();
#endif
    if (argc > 1) {
        local_resolution(argv[1]);
    }
    std::cout << "PASS engine options: classification, translation"
#ifdef LLAMA_TEST_ARGV_PARITY
              << ", argv parity"
#endif
              << (argc > 1 ? ", local resolution" : "") << "\n";
}
