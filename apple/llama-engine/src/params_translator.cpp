#include "params_translator.hpp"

#include "llama.h"

#include <stdexcept>
#include <thread>

namespace llama_engine {

using json = nlohmann::ordered_json;

ggml_type params_translator::map_kv_cache_type(llama_engine_kv_type t) {
    switch (t) {
        case LLAMA_ENGINE_KV_F32:    return GGML_TYPE_F32;
        case LLAMA_ENGINE_KV_F16:    return GGML_TYPE_F16;
        case LLAMA_ENGINE_KV_BF16:   return GGML_TYPE_BF16;
        case LLAMA_ENGINE_KV_Q8_0:   return GGML_TYPE_Q8_0;
        case LLAMA_ENGINE_KV_Q4_0:   return GGML_TYPE_Q4_0;
        case LLAMA_ENGINE_KV_Q5_0:   return GGML_TYPE_Q5_0;
        case LLAMA_ENGINE_KV_IQ4_NL: return GGML_TYPE_IQ4_NL;
    }
    throw std::invalid_argument("unknown kv_cache_type");
}

void params_translator::apply_extra_json(common_params & params, const json & extra) {
    if (extra.is_null()) {
        return;
    }
    if (!extra.is_object()) {
        throw std::invalid_argument("extra_json must be a JSON object");
    }

    // The escape hatch: these are consumed here as overrides on top of the
    // typed config. Only the keys below are recognised; unknown keys are
    // ignored by design to stay forward-compatible with upstream param
    // additions without failing the caller.
    if (extra.contains("n_batch"))                    params.n_batch                      = extra.at("n_batch").get<int32_t>();
    if (extra.contains("n_ubatch"))                   params.n_ubatch                     = extra.at("n_ubatch").get<int32_t>();
    if (extra.contains("n_keep"))                     params.n_keep                       = extra.at("n_keep").get<int32_t>();
    if (extra.contains("n_chunks"))                   params.n_chunks                     = extra.at("n_chunks").get<int32_t>();
    if (extra.contains("n_predict"))                  params.n_predict                    = extra.at("n_predict").get<int32_t>();
    if (extra.contains("grp_attn_n"))                 params.grp_attn_n                   = extra.at("grp_attn_n").get<int32_t>();
    if (extra.contains("grp_attn_w"))                 params.grp_attn_w                   = extra.at("grp_attn_w").get<int32_t>();
    if (extra.contains("rope_freq_base"))             params.rope_freq_base               = extra.at("rope_freq_base").get<float>();
    if (extra.contains("rope_freq_scale"))            params.rope_freq_scale              = extra.at("rope_freq_scale").get<float>();
    if (extra.contains("yarn_ext_factor"))            params.yarn_ext_factor              = extra.at("yarn_ext_factor").get<float>();
    if (extra.contains("yarn_attn_factor"))           params.yarn_attn_factor             = extra.at("yarn_attn_factor").get<float>();
    if (extra.contains("yarn_beta_fast"))             params.yarn_beta_fast               = extra.at("yarn_beta_fast").get<float>();
    if (extra.contains("yarn_beta_slow"))             params.yarn_beta_slow               = extra.at("yarn_beta_slow").get<float>();
    if (extra.contains("yarn_orig_ctx"))              params.yarn_orig_ctx                = extra.at("yarn_orig_ctx").get<int32_t>();
    if (extra.contains("slot_prompt_similarity"))     params.slot_prompt_similarity       = extra.at("slot_prompt_similarity").get<float>();
    if (extra.contains("cache_prompt"))               params.cache_prompt                 = extra.at("cache_prompt").get<bool>();
    if (extra.contains("kv_unified"))                 params.kv_unified                   = extra.at("kv_unified").get<bool>();
    if (extra.contains("cont_batching"))              params.cont_batching                = extra.at("cont_batching").get<bool>();
    if (extra.contains("use_jinja"))                  params.use_jinja                    = extra.at("use_jinja").get<bool>();
    if (extra.contains("swa_full"))                   params.swa_full                     = extra.at("swa_full").get<bool>();
    if (extra.contains("warmup"))                     params.warmup                       = extra.at("warmup").get<bool>();
    if (extra.contains("verbosity"))                  params.verbosity                    = extra.at("verbosity").get<int32_t>();
    if (extra.contains("image_min_tokens"))           params.image_min_tokens             = extra.at("image_min_tokens").get<int>();
    if (extra.contains("image_max_tokens"))           params.image_max_tokens             = extra.at("image_max_tokens").get<int>();
    if (extra.contains("media_path")) {
        // Gate for file:// URLs in chat image_url/input_audio parts. Matches
        // the behaviour of the amont --media-path flag: the path must be a
        // directory and end with a separator so it can be concatenated with
        // the relative path parsed from the file:// URL.
        std::string mp = extra.at("media_path").get<std::string>();
        if (!mp.empty() && mp.back() != '/') {
            mp.push_back('/');
        }
        params.media_path = std::move(mp);
    }
}

common_params params_translator::translate(const llama_engine_config & cfg) {
    if (cfg.model_path == nullptr || cfg.model_path[0] == '\0') {
        throw std::invalid_argument("model_path is required");
    }

    common_params p;

    p.model.path = cfg.model_path;

    if (cfg.context_size > 0) {
        p.n_ctx = cfg.context_size;
    }

    p.n_gpu_layers = cfg.gpu_layers;

    p.n_parallel = cfg.parallel_slots > 0 ? cfg.parallel_slots : 1;

    if (cfg.cpu_threads > 0) {
        p.cpuparams.n_threads       = cfg.cpu_threads;
        p.cpuparams_batch.n_threads = cfg.cpu_threads;
    } else {
        const int hw = static_cast<int>(std::thread::hardware_concurrency());
        if (hw > 0) {
            p.cpuparams.n_threads       = hw;
            p.cpuparams_batch.n_threads = hw;
        }
    }

    p.sampling.seed = cfg.seed;

    if (cfg.mtmd_projector_path != nullptr && cfg.mtmd_projector_path[0] != '\0') {
        p.mmproj.path = cfg.mtmd_projector_path;    
        // Disable context shifting when multimodal is enabled
        // This is because an media chunk may contain multiple tokens
        // and context shifting could break the media representation
        p.ctx_shift = false;
    }

    if (cfg.chat_template_override != nullptr && cfg.chat_template_override[0] != '\0') {
        p.chat_template = cfg.chat_template_override;
    }

    p.use_mmap           = cfg.use_mmap;
    p.use_mlock          = cfg.use_mlock;
    p.flash_attn_type    = cfg.flash_attention ? LLAMA_FLASH_ATTN_TYPE_ENABLED
                                               : LLAMA_FLASH_ATTN_TYPE_AUTO;
    p.cache_type_k       = map_kv_cache_type(cfg.kv_cache_type);
    p.cache_type_v       = map_kv_cache_type(cfg.kv_cache_type);
    p.sleep_idle_seconds = cfg.idle_pause_seconds;

    // Server defaults that we want consistently applied for library use.
    p.embedding          = false;
    p.warmup             = false;
    p.use_jinja          = true;
    p.cache_prompt       = true;
    p.cont_batching      = true;
    p.kv_unified         = cfg.parallel_slots <= 1;

    if (cfg.extra_json != nullptr && cfg.extra_json[0] != '\0') {
        json extra;
        try {
            extra = json::parse(cfg.extra_json);
        } catch (const json::parse_error & e) {
            throw std::invalid_argument(std::string("extra_json: ") + e.what());
        }
        apply_extra_json(p, extra);
    }

    return p;
}

} // namespace llama_engine
