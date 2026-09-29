#include "engine-catalog.h"
#include "engine-options.h"
#include "engine-runtime.h"
#include "server-common.h"

#include "arg.h"
#include "download.h"
#include "hf-cache.h"

namespace llama_engine { namespace detail {

std::map<std::string, catalog_preset> read_catalog_presets(const common_preset_context & ctx, bool cache,
                                                           const std::string & models_dir,
                                                           const std::string & presets_file,
                                                           const common_preset & base) {
    // 1. cached models
    common_presets cached_models;
    if (cache) {
        cached_models = ctx.load_from_cache();
        SRV_TRC("Loaded %zu cached model presets from %s\n", cached_models.size(), hf_cache::get_cache_path().c_str());
    }
    // 2. local models from --models-dir
    common_presets local_models;
    if (!models_dir.empty()) {
        local_models = ctx.load_from_models_dir(models_dir);
        SRV_TRC("Loaded %zu local model presets from %s\n", local_models.size(), models_dir.c_str());
    }
    // 3. custom-path models from presets
    common_preset global = {};
    common_presets custom_presets = {};
    if (!presets_file.empty()) {
        custom_presets = ctx.load_from_ini(presets_file, global);
        SRV_TRC("Loaded %zu custom model presets from %s\n", custom_presets.size(), presets_file.c_str());
    }

    // cascade, apply global preset first
    cached_models  = ctx.cascade(global, cached_models);
    local_models   = ctx.cascade(global, local_models);
    custom_presets = ctx.cascade(global, custom_presets);

    // note: if a model exists in both cached and local, local takes precedence
    std::map<std::string, catalog_preset> out;
    for (const auto & [name, preset] : cached_models) {
        out[name] = {preset, "cache", false};
    }
    for (const auto & [name, preset] : local_models) {
        out[name] = {preset, "models_dir", false};
    }
    for (const auto & [name, custom] : custom_presets) {
        if (out.find(name) != out.end()) {
            out[name].preset.merge(custom);
        } else {
            out[name].preset = custom;
        }
        out[name].source = "preset";
    }

    // overlay the base options (e.g. the router's own CLI args) on top of every
    // model preset so that e.g. `llama-server --temp 0` is honoured by all models
    for (auto & [name, entry] : out) {
        entry.preset.merge(base);
    }

    // hide cache models whose resolved file is already used by a preset with dedup-cache-models enabled
    std::set<std::string> preset_paths;
    auto add_hf_path = [&preset_paths](const common_preset & preset, const char * repo_key, const char * file_key) {
        std::string hf_repo;
        if (!preset.get_option(repo_key, hf_repo) || hf_repo.empty()) {
            return;
        }
        std::string hf_file;
        preset.get_option(file_key, hf_file);
        std::string path = common_download_resolve_path(hf_repo, hf_file);
        if (!path.empty()) {
            preset_paths.insert(path);
        }
    };
    for (const auto & [name, preset] : custom_presets) {
        std::string val;
        if (!preset.get_option(COMMON_ARG_PRESET_DEDUP_CACHE_MODELS, val) || !common_arg_utils::is_truthy(val)) {
            continue;
        }
        add_hf_path(preset, "LLAMA_ARG_HF_REPO", "LLAMA_ARG_HF_FILE");
        add_hf_path(preset, "LLAMA_ARG_SPEC_DRAFT_HF_REPO", "LLAMA_ARG_SPEC_DRAFT_MODEL");
    }
    if (!preset_paths.empty()) {
        for (const auto & [name, preset] : cached_models) {
            if (out.at(name).source != "cache") {
                continue; // merged with another source, not a pure cache entry
            }
            std::string path = common_download_resolve_path(name);
            if (!path.empty() && preset_paths.count(path)) {
                SRV_INF("hiding cache model name=%s (deduplicated by a preset)\n", name.c_str());
                out.at(name).hidden = true;
            }
        }
    }
    return out;
}

std::set<std::string> preset_list(const common_preset & preset, const char * env) {
    std::set<std::string> out;
    std::string value;
    if (preset.get_option(env, value) && !value.empty()) {
        for (auto & item : string_split<std::string>(value, ',')) {
            item = string_strip(item);
            if (!item.empty()) {
                out.insert(item);
            }
        }
    }
    return out;
}

} } // namespace llama_engine::detail

namespace llama_engine {

event read_catalog(const catalog_sources & sources, std::vector<model_entry> & models) {
    using namespace detail;
    models.clear();
    try {
        const common_preset_context ctx(LLAMA_EXAMPLE_SERVER);
        common_preset base = ctx.load_from_map(COMMON_PRESET_DEFAULT_NAME, sources.options);
        for (const auto & [opt, value] : base.options) {
            const auto * scope = find_option_scope(option_key(opt));
            if (!scope || *scope == option_scope::catalog || opt.env == std::string("LLAMA_ARG_MODEL") ||
                opt.env == std::string("LLAMA_ARG_MMPROJ") || opt.env == std::string("LLAMA_ARG_HF_REPO")) {
                // model identity and catalog composition are per model, as in llama-server
                return {event_type::error, nullptr, "invalid_config",
                        "option '" + option_key(opt) + "' cannot apply to every model"};
            }
        }
        const auto presets = read_catalog_presets(ctx, sources.cache, sources.models_dir, sources.presets, base);

        std::set<std::string> taken; // names, then aliases in order
        for (const auto & [name, found] : presets) {
            taken.insert(name);
        }
        for (const auto & [name, found] : presets) {
            model_entry entry;
            entry.id     = name;
            entry.source = found.source;
            entry.hidden = found.hidden;
            const auto tags = preset_list(found.preset, "LLAMA_ARG_TAGS");
            entry.tags.assign(tags.begin(), tags.end());
            for (const auto & alias : preset_list(found.preset, "LLAMA_ARG_ALIAS")) {
                if (taken.insert(alias).second) {
                    entry.aliases.push_back(alias);
                } else if (sources.skip_conflicting_aliases) {
                    SRV_WRN("(reload) alias '%s' for model '%s' conflicts with another model, skipping\n", alias.c_str(), name.c_str());
                } else {
                    return {event_type::error, nullptr, "invalid_config",
                            "alias '" + alias + "' for model '" + name + "' conflicts with another model name or alias"};
                }
            }
            std::map<std::string, std::string> options;
            for (const auto & [opt, value] : found.preset.options) {
                const std::string key = option_key(opt);
                const auto * scope = find_option_scope(key);
                if (opt.env && std::string(opt.env) == COMMON_ARG_PRESET_LOAD_ON_STARTUP) {
                    entry.load_on_startup = common_arg_utils::is_truthy(value);
                } else if (scope && *scope == option_scope::engine) {
                    options[key] = value;
                } else if (scope && *scope == option_scope::host) {
                    entry.host_options[key] = value; // e.g. stop-timeout, per-model HTTP settings
                }
                // other catalog options (alias, tags, models-*) are consumed here
            }
            entry.settings = config::from_options(std::move(options));
            std::string error;
            if (!valid_config(entry.settings, error)) {
                entry.error = error; // listed, and fails to load with this message
            }
            models.push_back(std::move(entry));
        }
    } catch (const std::exception & e) {
        models.clear();
        return {event_type::error, nullptr, "invalid_config", e.what()};
    }
    return {event_type::success, nullptr, {}, {}};
}

} // namespace llama_engine
