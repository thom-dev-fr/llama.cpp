#pragma once

#include "llama-engine.h"
#include "common.h"

#include <string>

struct common_arg;
class common_download_callback;
struct common_download_remote;

namespace llama_engine { namespace detail {

// Owner of each named option (see the table in engine-options.cpp).
enum class option_scope { engine, host, catalog };

// Canonical key of a registry option: its last spelling without leading dashes.
std::string option_key(const common_arg & opt);
// nullptr when the option is not classified.
const option_scope * find_option_scope(const std::string & key);

// Model configuration -> common_params: llama-server defaults, typed fields,
// options (engine scope only), common_params_finalize, apply_server_defaults.
// Remote resources are not resolved. Throws std::invalid_argument when the
// configuration is invalid.
common_params build_params(const config & settings);

// Adjustments that llama-server applies after parsing (embedding batch and
// automatic slots when a model is loaded; KV pool per slot, default alias).
// Shared with the executable so both follow one rule.
void apply_server_defaults(common_params & params, bool loads_model);

// Resolves hf/url/docker resources to local files: through the network when the
// engine is built with acquisition, otherwise from local files and the cache only
// (common_download_unavailable for anything missing). callback reports progress
// and cancellation of downloads.
void resolve_resources(common_params & params, common_download_callback * callback);

// Same loading configuration and limits (a model loaded with a must be reloaded for b otherwise).
bool same_config(const config & a, const config & b);

// Catalog id of a single-model configuration: model file name or repository.
std::string model_name(const config & settings);

// Whether this build includes network acquisition.
bool has_acquisition();
// The network transport of this build, nullptr without acquisition.
const common_download_remote * download_transport();

} } // namespace llama_engine::detail
