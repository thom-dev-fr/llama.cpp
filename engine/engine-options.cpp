#include "engine-options.h"

#include "arg.h"
#include "download.h"
#include "log.h"
#include "preset.h"
#include "server-common.h"

#include <filesystem>
#include <map>
#include <sstream>
#include <tuple>

namespace llama_engine { namespace detail {

namespace {
// Every option of the llama-server and llama-cli registries, by canonical key
// (last spelling without dashes). test-engine-options fails when an option is
// added upstream without a decision here.
//  - engine:  applied to the model (loading, context, sampling defaults,
//             templates, speculative decoding, resources and their acquisition)
//  - host:    transport, UI, tools, logging, terminal and process-wide state
//             (process priority, NUMA, RPC backend registration, exit actions)
//  - catalog: catalog composition, read by load_catalog
const std::map<std::string, option_scope> & scopes() {
    static const std::map<std::string, option_scope> table = [] {
        std::map<std::string, option_scope> out;
        const auto add = [&](const char * keys, option_scope scope) {
            std::istringstream in(keys);
            for (std::string key; in >> key;) { out[key] = scope; }
        };
        add(R"(
        threads threads-batch cpu-mask cpu-range cpu-strict poll cpu-mask-batch cpu-range-batch
        cpu-strict-batch poll-batch lookup-cache-static lookup-cache-dynamic ctx-size kv-unified-per-slot
        n-predict batch-size ubatch-size keep swa-full swa-checkpoints checkpoint-min-step cache-ram
        kv-unified cache-idle-slots context-shift flash-attn perf escape reverse-prompt special warmup
        spm-infill samplers seed sampling-seq ignore-eos temperature top-k top-p min-p top-n-sigma
        xtc-probability xtc-threshold typical-p repeat-last-n repeat-penalty presence-penalty
        frequency-penalty dry-multiplier dry-base dry-allowed-length dry-penalty-last-n dry-sequence-breaker
        adaptive-target adaptive-decay dynatemp-range dynatemp-exp mirostat mirostat-lr mirostat-ent
        logit-bias grammar grammar-file json-schema json-schema-file backend-sampling pooling rope-scaling
        rope-scale rope-freq-base rope-freq-scale yarn-orig-ctx yarn-ext-factor yarn-attn-factor
        yarn-beta-slow yarn-beta-fast kv-offload repack no-host cache-type-k cache-type-v defrag-thold
        parallel cont-batching mmproj mmproj-url mmproj-auto mmproj-offload mmproj-device image-min-tokens
        image-max-tokens mtmd-batch-max-tokens video-fps video-timestamp-interval video-ffmpeg-dir load-mode
        lazy-mode device override-tensor cpu-moe n-cpu-moe n-cpu-ffn n-gpu-layers split-mode tensor-split
        main-gpu fit fit-target fit-ctx check-tensors override-kv op-offload lora lora-scaled control-vector
        control-vector-scaled control-vector-layer-range model model-url docker-repo hf-repo hf-file
        hf-token embd-normalize embeddings reranking chat-template-kwargs cache-prompt cache-reuse
        slot-save-path media-path jinja reasoning-format reasoning reasoning-effort reasoning-budget
        reasoning-budget-message reasoning-preserve chat-template chat-template-file skip-chat-parsing
        prefill-assistant slot-prompt-similarity lora-init-without-apply sleep-idle-seconds log-prompts-dir
        offline hf-repo-draft threads-draft threads-batch-draft cpu-mask-draft cpu-range-draft
        cpu-strict-draft poll-draft cpu-mask-batch-draft cpu-strict-batch-draft poll-batch-draft
        cache-type-k-draft cache-type-v-draft override-tensor-draft cpu-moe-draft n-cpu-moe-draft
        spec-draft-n-max spec-draft-n-min spec-synth-len spec-synth-rates draft-p-split draft-p-min
        spec-draft-backend-sampling device-draft n-gpu-layers-draft model-draft spec-type
        spec-ngram-mod-n-min spec-ngram-mod-n-max spec-ngram-mod-n-match spec-ngram-simple-size-n
        spec-ngram-simple-size-m spec-ngram-simple-min-hits spec-ngram-map-k-size-n spec-ngram-map-k-size-m
        spec-ngram-map-k-min-hits spec-ngram-map-k4v-size-n spec-ngram-map-k4v-size-m
        spec-ngram-map-k4v-min-hits draft-max draft-n-min spec-ngram-size-n spec-ngram-size-m
        spec-ngram-min-hits embd-gemma-default fim-qwen-1.5b-default fim-qwen-3b-default fim-qwen-7b-default
        fim-qwen-7b-spec fim-qwen-14b-spec fim-qwen-30b-default gpt-oss-20b-default gpt-oss-120b-default
        vision-gemma-4b-default vision-gemma-12b-default spec-default
        )", option_scope::engine);
        add(R"(
        usage version cache-list completion-bash list-devices rpc numa prio prio-batch prio-draft
        prio-batch-draft host port reuse-port path cors-origins cors-methods cors-headers cors-credentials
        api-prefix webui-config webui-config-file webui-mcp-proxy tools tools-runtime mcp-servers-config
        mcp-servers-json agent webui api-key api-key-file ssl-key-file ssl-cert-file timeout
        sse-ping-interval threads-http metrics props slots log-disable log-file log-jsonl log-colors
        log-verbose log-verbosity log-prefix log-timestamps stop-timeout binary-file color display-prompt
        file multiline-input output-file prompt server-base show-timings simple-io single-turn system-prompt
        system-prompt-file verbose-prompt video
        )", option_scope::host);
        add(R"(
        alias tags models-dir models-preset models-max models-autoload load-on-startup dedup-cache-models
        )", option_scope::catalog);
        return out;
    }();
    return table;
}

std::string rm_dashes(const std::string & arg) {
    size_t pos = 0;
    while (pos < arg.size() && arg[pos] == '-') { pos++; }
    return arg.substr(pos);
}

// Typed fields as options: they go through the same handlers as the command
// line, so markers set by handlers (explicit context size, ...) are identical.
struct typed_option { const char * key; const char * field; std::string value; };

std::vector<typed_option> typed_options(const config & s) {
    std::vector<typed_option> out;
    const auto add_int = [&](const char * key, const char * field, const std::optional<int> & v) {
        if (v) { out.push_back({key, field, std::to_string(*v)}); }
    };
    if (!s.model_path.empty()) { out.push_back({"model", "model_path", s.model_path}); }
    add_int("ctx-size",     "context_size",     s.context_size);
    add_int("parallel",     "parallel",         s.parallel);
    add_int("threads",      "threads",          s.threads);
    add_int("n-gpu-layers", "gpu_layers",       s.gpu_layers);
    add_int("batch-size",   "batch_size",       s.batch_size);
    add_int("ubatch-size",  "micro_batch_size", s.micro_batch_size);
    if (s.fit)    { out.push_back({"fit",    "fit",    *s.fit    ? "on"   : "off"}); }
    if (s.warmup) { out.push_back({"warmup", "warmup", *s.warmup ? "true" : "false"}); }
    if (!s.chat_template.empty()) { out.push_back({"chat-template", "chat_template", s.chat_template}); }
    if (!s.mmproj_path.empty())   { out.push_back({"mmproj", "mmproj_path", s.mmproj_path}); }
    if (s.embeddings)             { out.push_back({"embeddings", "embeddings", "true"}); }
    if (s.pooling_type != -1) {
        static const char * names[] = {"none", "mean", "cls", "last", "rank"};
        if (s.pooling_type < 0 || s.pooling_type > 4) {
            throw std::invalid_argument("invalid pooling_type");
        }
        out.push_back({"pooling", "pooling_type", names[s.pooling_type]});
    }
    if (!s.slot_save_path.empty()) { out.push_back({"slot-save-path", "slot_save_path", s.slot_save_path}); }
    if (!s.lora_paths.empty()) {
        std::string csv;
        for (const auto & path : s.lora_paths) {
            std::string quoted = path;
            string_replace_all(quoted, "\"", "\"\"");
            csv += (csv.empty() ? "" : ",") + ("\"" + quoted + "\"");
        }
        out.push_back({"lora", "lora_paths", csv});
    }
    if (s.sleep_idle_seconds != -1) {
        out.push_back({"sleep-idle-seconds", "sleep_idle_seconds", std::to_string(s.sleep_idle_seconds)});
    }
    return out;
}

const common_preset_context & preset_context() {
    // key parsing only; handlers are pure functions of the params they receive
    static const common_preset_context ctx(LLAMA_EXAMPLE_SERVER);
    return ctx;
}

const common_params & server_defaults() {
    static const common_params defaults = [] {
        common_params params;
        common_params_parser_init(params, LLAMA_EXAMPLE_SERVER); // per-example defaults
        return params;
    }();
    return defaults;
}
} // namespace

std::string option_key(const common_arg & opt) {
    return opt.args.empty() ? std::string() : rm_dashes(opt.args.back());
}


common_params build_params(const config & settings) {
    const auto & ctx = preset_context();

    common_preset typed;
    std::map<common_arg, std::string> typed_fields; // option -> config field
    for (const auto & t : typed_options(settings)) {
        const auto & opt = ctx.key_to_opt.at(t.key);
        typed.options[opt] = t.value;
        typed_fields[opt] = t.field;
    }

    common_preset user;
    try {
        user = ctx.load_from_map("config", settings.options);
    } catch (const std::exception & e) {
        throw std::invalid_argument(e.what());
    }
    for (const auto & [opt, value] : user.options) {
        const std::string key = option_key(opt);
        const option_scope scope = find_option_scope(key);
        if (scope == option_scope::unknown) {
            throw std::invalid_argument("option '" + key + "' is not supported by the engine");
        }
        if (scope == option_scope::host) {
            throw std::invalid_argument("option '" + key + "' belongs to the host application, not the engine");
        }
        if (scope == option_scope::catalog) {
            throw std::invalid_argument("option '" + key + "' configures the catalog, not a model");
        }
        auto field = typed_fields.find(opt);
        if (field != typed_fields.end()) {
            throw std::invalid_argument("option '" + key + "' conflicts with config::" + field->second);
        }
    }

    common_preset merged = typed;
    merged.merge(user);
    // the projector follows a CPU-only typed configuration unless an option says otherwise
    const auto & offload = ctx.key_to_opt.at("mmproj-offload");
    if (settings.gpu_layers && *settings.gpu_layers == 0 && !merged.options.count(offload)) {
        merged.options[offload] = "false";
    }

    common_params params = server_defaults();
    for (const auto & [opt, value] : merged.options) {
        common_preset one;
        one.options[opt] = value;
        try {
            one.apply_to_params(params);
        } catch (const std::exception & e) {
            throw std::invalid_argument("invalid value '" + value + "' for option '" + option_key(opt) + "': " + e.what());
        }
    }
    try {
        common_params_finalize(params);
    } catch (const std::exception & e) {
        throw std::invalid_argument(e.what());
    }
    if (params.model.empty() && params.model.url.empty()) {
        throw std::invalid_argument("no model configured (model_path or a model option)");
    }
    apply_server_defaults(params, true);
    return params;
}

void apply_server_defaults(common_params & params, bool loads_model) {
    if (loads_model) {
        // validate batch size for embeddings
        // embeddings require all tokens to be processed in a single ubatch
        // see https://github.com/ggml-org/llama.cpp/issues/12836
        if (params.embedding && params.n_batch > params.n_ubatch) {
            SRV_WRN("embeddings enabled with n_batch (%d) > n_ubatch (%d)\n", params.n_batch, params.n_ubatch);
            SRV_WRN("setting n_batch = n_ubatch = %d to avoid assertion failure\n", params.n_ubatch);
            params.n_batch = params.n_ubatch;
        }

        if (params.n_parallel < 0) {
            SRV_TRC("%s", "n_parallel is set to auto, using n_parallel = 4 and kv_unified = true\n");

            params.n_parallel = 4;
            params.kv_unified = true;
        }
    }

    // size the KV pool from --kv-unified-per-slot, unless the user pinned it with -c
    // or with -c 0 for max context
    const bool ctx_pool_auto_sized = params.kv_unified_per_slot > 0 &&
                                     params.n_ctx == 0 &&
                                     (uint32_t) params.fit_params_min_ctx != UINT32_MAX;

    if (ctx_pool_auto_sized) {
        params.n_ctx = params.n_parallel * params.kv_unified_per_slot;
        SRV_INF("--kv-unified-per-slot: sizing KV pool to n_parallel * kv_unified_per_slot = %d * %d = %d\n", params.n_parallel,
                params.kv_unified_per_slot, params.n_ctx);
    }

    // for consistency between server router mode and single-model mode, we set the same model name as alias
    auto model_name = params.model.get_name();
    if (params.model_alias.empty() && !model_name.empty()) {
        params.model_alias.insert(model_name);
    }
}

bool same_config(const config & a, const config & b) {
    const auto fields = [](const config & c) {
        return std::tie(c.model_path, c.context_size, c.parallel, c.threads, c.gpu_layers, c.batch_size,
                        c.micro_batch_size, c.fit, c.warmup, c.chat_template, c.mmproj_path, c.embeddings,
                        c.pooling_type, c.slot_save_path, c.lora_paths, c.sleep_idle_seconds, c.options,
                        c.max_tasks, c.max_events, c.max_request_bytes, c.generation_defaults);
    };
    return fields(a) == fields(b);
}

bool has_acquisition() {
#ifdef LLAMA_ENGINE_ACQUISITION
    return true;
#else
    return false;
#endif
}

const common_download_remote * download_transport() {
#ifdef LLAMA_ENGINE_ACQUISITION
    return &common_download_network();
#else
    return nullptr;
#endif
}

void resolve_resources(common_params & params, common_download_callback * callback) {
    const common_download_remote * remote = download_transport();
    auto handler = common_models_handler_init(params, LLAMA_EXAMPLE_SERVER, remote);
    if (common_models_handler_is_preset_repo(handler)) {
        throw std::invalid_argument("'" + params.model.hf_repo + "' is a preset repository, not a model");
    }
    common_models_handler_apply(handler, params, remote, callback);
}

} } // namespace llama_engine::detail

namespace llama_engine {

option_scope find_option_scope(const std::string & name) {
    std::string key = detail::rm_dashes(name);
    const auto & ctx = detail::preset_context();
    auto opt = ctx.key_to_opt.find(key); // other spellings: negated form, LLAMA_ARG_*
    if (opt != ctx.key_to_opt.end()) {
        key = detail::option_key(opt->second);
    }
    const auto & table = detail::scopes();
    auto it = table.find(key);
    return it == table.end() ? option_scope::unknown : it->second;
}

std::string model_id(const config & settings) {
    if (!settings.model_path.empty()) {
        return fs_path_to_utf8(std::filesystem::u8path(settings.model_path).filename());
    }
    const common_params params = detail::build_params(settings);
    if (!params.model.path.empty()) {
        return fs_path_to_utf8(std::filesystem::u8path(params.model.path).filename());
    }
    if (!params.model.get_name().empty()) {
        return params.model.get_name(); // repository
    }
    // plain URL: its file name, as the download would name it
    auto file = string_split<std::string>(params.model.url, '#').front();
    file = string_split<std::string>(file, '?').front();
    return string_split<std::string>(file, '/').back();
}

} // namespace llama_engine
