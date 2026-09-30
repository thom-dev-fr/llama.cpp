#pragma once

#include "llama-engine.h"
#include "preset.h"

#include <map>
#include <string>

namespace llama_engine { namespace detail {

// One model found in the configured sources, before translation.
struct catalog_preset {
    common_preset preset;
    std::string source; // "cache", "models_dir" or "preset"
    bool hidden = false; // cache entry already provided by a preset (dedup-cache-models)
};

// Reads the sources with llama-server's rules: cached models, replaced by a
// models_dir model of the same name, then merged with the INI section of that
// name; under, then the INI global section ("*") under each, and base over every model.
// Reads files and the cache only: no network, no write.
std::map<std::string, catalog_preset> read_catalog_presets(const common_preset_context & ctx, bool cache,
                                                           const std::string & models_dir,
                                                           const std::string & presets_file,
                                                           const common_preset & base,
                                                           const common_preset & under = {});

// Input modalities of a configured model, from its projector found locally
// (files or cache): "text", then "image"/"audio". No network.
std::vector<std::string> local_modalities(const config & settings);

// Comma-separated list option (alias, tags) of a preset.
std::set<std::string> preset_list(const common_preset & preset, const char * env);

} } // namespace llama_engine::detail
