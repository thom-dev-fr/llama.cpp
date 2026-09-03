#include "caps_probe.hpp"

#include "ggml.h"
#include "gguf.h"

#include "chat.h"
#include "log.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <sys/stat.h>

namespace llama_engine {

namespace {

// -----------------------------------------------------------------------------
// GGUF helpers (lookup-by-key with type checks; never abort the process).
// -----------------------------------------------------------------------------

static bool gguf_get_str_at(const gguf_context * ctx, int64_t kid, std::string & out) {
    if (kid < 0) return false;
    if (gguf_get_kv_type(ctx, kid) != GGUF_TYPE_STRING) return false;
    const char * s = gguf_get_val_str(ctx, kid);
    if (!s) return false;
    out = s;
    return true;
}

static bool gguf_get_str(const gguf_context * ctx, const char * key, std::string & out) {
    return gguf_get_str_at(ctx, gguf_find_key(ctx, key), out);
}

static bool clamp_u64_to_u32(uint64_t v, uint32_t & out) {
    out = v > UINT32_MAX ? UINT32_MAX : (uint32_t) v;
    return true;
}

static bool clamp_i64_to_u32(int64_t v, uint32_t & out) {
    out = v < 0 ? 0u : (v > (int64_t) UINT32_MAX ? UINT32_MAX : (uint32_t) v);
    return true;
}

static bool gguf_get_u32_at(const gguf_context * ctx, int64_t kid, uint32_t & out) {
    if (kid < 0) return false;
    const auto t = gguf_get_kv_type(ctx, kid);
    switch (t) {
        case GGUF_TYPE_UINT32: out = gguf_get_val_u32(ctx, kid);            return true;
        case GGUF_TYPE_INT32:  return clamp_i64_to_u32(gguf_get_val_i32(ctx, kid), out);
        case GGUF_TYPE_UINT64: return clamp_u64_to_u32(gguf_get_val_u64(ctx, kid), out);
        case GGUF_TYPE_INT64:  return clamp_i64_to_u32(gguf_get_val_i64(ctx, kid), out);
        case GGUF_TYPE_ARRAY: {
            const size_t n = gguf_get_arr_n(ctx, kid);
            if (n == 0) return false;

            // Some GGUF hparams can be stored as per-layer arrays. Expose a
            // single conservative scalar by taking the maximum element.
            uint64_t max_v = 0;
            switch (gguf_get_arr_type(ctx, kid)) {
                case GGUF_TYPE_UINT32: {
                    const auto * data = (const uint32_t *) gguf_get_arr_data(ctx, kid);
                    if (!data) return false;
                    for (size_t i = 0; i < n; ++i) max_v = std::max<uint64_t>(max_v, data[i]);
                    return clamp_u64_to_u32(max_v, out);
                }
                case GGUF_TYPE_INT32: {
                    const auto * data = (const int32_t *) gguf_get_arr_data(ctx, kid);
                    if (!data) return false;
                    for (size_t i = 0; i < n; ++i) max_v = std::max<uint64_t>(max_v, data[i] < 0 ? 0u : (uint32_t) data[i]);
                    return clamp_u64_to_u32(max_v, out);
                }
                case GGUF_TYPE_UINT64: {
                    const auto * data = (const uint64_t *) gguf_get_arr_data(ctx, kid);
                    if (!data) return false;
                    for (size_t i = 0; i < n; ++i) max_v = std::max<uint64_t>(max_v, data[i]);
                    return clamp_u64_to_u32(max_v, out);
                }
                case GGUF_TYPE_INT64: {
                    const auto * data = (const int64_t *) gguf_get_arr_data(ctx, kid);
                    if (!data) return false;
                    for (size_t i = 0; i < n; ++i) max_v = std::max<uint64_t>(max_v, data[i] < 0 ? 0ull : (uint64_t) data[i]);
                    return clamp_u64_to_u32(max_v, out);
                }
                default: return false;
            }
        }
        default: return false;
    }
}

static bool gguf_get_u32(const gguf_context * ctx, const char * key, uint32_t & out) {
    return gguf_get_u32_at(ctx, gguf_find_key(ctx, key), out);
}

static bool gguf_get_bool_at(const gguf_context * ctx, int64_t kid, bool & out) {
    if (kid < 0) return false;
    if (gguf_get_kv_type(ctx, kid) != GGUF_TYPE_BOOL) return false;
    out = gguf_get_val_bool(ctx, kid);
    return true;
}

static bool gguf_get_bool_lenient(const gguf_context * ctx, const char * key, bool & out) {
    return gguf_get_bool_at(ctx, gguf_find_key(ctx, key), out);
}

static bool ends_with(const std::string & value, const char * suffix) {
    const size_t n = std::strlen(suffix);
    return value.size() >= n && value.compare(value.size() - n, n, suffix) == 0;
}

static bool gguf_get_u32_by_suffix(const gguf_context * ctx, const char * suffix, uint32_t & out) {
    const int64_t n_kv = gguf_get_n_kv(ctx);
    for (int64_t i = 0; i < n_kv; ++i) {
        const char * key = gguf_get_key(ctx, i);
        if (key && ends_with(key, suffix) && gguf_get_u32_at(ctx, i, out)) {
            return true;
        }
    }
    return false;
}

static bool gguf_get_str_by_suffix(const gguf_context * ctx, const char * suffix, std::string & out) {
    const int64_t n_kv = gguf_get_n_kv(ctx);
    for (int64_t i = 0; i < n_kv; ++i) {
        const char * key = gguf_get_key(ctx, i);
        if (key && ends_with(key, suffix) && gguf_get_str_at(ctx, i, out)) {
            return true;
        }
    }
    return false;
}

static bool gguf_get_bool_by_suffix(const gguf_context * ctx, const char * suffix, bool & out) {
    const int64_t n_kv = gguf_get_n_kv(ctx);
    for (int64_t i = 0; i < n_kv; ++i) {
        const char * key = gguf_get_key(ctx, i);
        if (key && ends_with(key, suffix) && gguf_get_bool_at(ctx, i, out)) {
            return true;
        }
    }
    return false;
}

// Format a `general.file_type` enum value as a quantization label, mirroring
// upstream's static llama_model_ftype_name() in src/llama-model-loader.cpp.
// Inlined here because the upstream function is not exported.
static const char * ftype_label(uint32_t ftype) {
    // The "guessed" bit (1 << 31 in some codebases, but actually just an
    // additive flag in upstream; we mask it conservatively).
    constexpr uint32_t GUESSED = 1024; // LLAMA_FTYPE_GUESSED in llama.h
    const uint32_t f   = ftype & ~GUESSED;
    const char * name  = nullptr;
    switch (f) {
        case 0:  name = "all F32";                       break;
        case 1:  name = "F16";                           break;
        case 2:  name = "Q4_0";                          break;
        case 3:  name = "Q4_1";                          break;
        case 7:  name = "Q8_0";                          break;
        case 8:  name = "Q5_0";                          break;
        case 9:  name = "Q5_1";                          break;
        case 10: name = "Q2_K - Medium";                 break;
        case 11: name = "Q3_K - Small";                  break;
        case 12: name = "Q3_K - Medium";                 break;
        case 13: name = "Q3_K - Large";                  break;
        case 14: name = "Q4_K - Small";                  break;
        case 15: name = "Q4_K - Medium";                 break;
        case 16: name = "Q5_K - Small";                  break;
        case 17: name = "Q5_K - Medium";                 break;
        case 18: name = "Q6_K";                          break;
        case 19: name = "IQ2_XXS - 2.0625 bpw";          break;
        case 20: name = "IQ2_XS - 2.3125 bpw";           break;
        case 21: name = "Q2_K - Small";                  break;
        case 22: name = "IQ3_XS - 3.3 bpw";              break;
        case 23: name = "IQ3_XXS - 3.0625 bpw";          break;
        case 24: name = "IQ1_S - 1.5625 bpw";            break;
        case 25: name = "IQ4_NL - 4.5 bpw";              break;
        case 26: name = "IQ3_S - 3.4375 bpw";            break;
        case 27: name = "IQ3_S mix - 3.66 bpw";          break;
        case 28: name = "IQ2_S - 2.5 bpw";               break;
        case 29: name = "IQ2_M - 2.7 bpw";               break;
        case 30: name = "IQ4_XS - 4.25 bpw";             break;
        case 31: name = "IQ1_M - 1.75 bpw";              break;
        case 32: name = "BF16";                          break;
        case 36: name = "TQ1_0 - 1.69 bpw ternary";      break;
        case 37: name = "TQ2_0 - 2.06 bpw ternary";      break;
        case 38: name = "MXFP4 MoE";                     break;
        case 39: name = "Q1_0";                          break;
        case 40: name = "NVFP4";                         break;
        default: name = "unknown, may not work";         break;
    }
    return name;
}

// strdup() to malloc'd memory with explicit empty handling.
static char * heap_str(const std::string & s) {
    char * out = (char *) std::malloc(s.size() + 1);
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

static uint64_t file_size_or_zero(const char * path) {
    struct stat st{};
    if (::stat(path, &st) != 0) return 0;
    return (uint64_t) st.st_size;
}

static void free_string_array(char ** arr, size_t n) {
    if (!arr) return;
    for (size_t i = 0; i < n; ++i) {
        std::free(arr[i]);
    }
    std::free(arr);
}

static bool gguf_get_str_array(const gguf_context * ctx, const char * key, char *** out, size_t * out_n) {
    if (out) *out = nullptr;
    if (out_n) *out_n = 0;
    const int64_t kid = gguf_find_key(ctx, key);
    if (kid < 0) return false;
    if (gguf_get_kv_type(ctx, kid) != GGUF_TYPE_ARRAY) return false;
    if (gguf_get_arr_type(ctx, kid) != GGUF_TYPE_STRING) return false;

    const size_t n = gguf_get_arr_n(ctx, kid);
    char ** arr = nullptr;
    if (n > 0) {
        arr = (char **) std::calloc(n, sizeof(char *));
        if (!arr) return false;
    }

    for (size_t i = 0; i < n; ++i) {
        const char * s = gguf_get_arr_str(ctx, kid, i);
        arr[i] = heap_str(s ? std::string(s) : std::string());
        if (!arr[i]) {
            free_string_array(arr, n);
            return false;
        }
    }

    if (out) *out = arr;
    if (out_n) *out_n = n;
    return true;
}

static void fill_arch_u32(const gguf_context * ctx,
                          const std::string & arch,
                          const char * arch_suffix,
                          const char * fallback_suffix,
                          bool & has,
                          uint32_t & value) {
    uint32_t tmp = 0;
    if (!arch.empty()) {
        const std::string key = arch + arch_suffix;
        if (gguf_get_u32(ctx, key.c_str(), tmp)) {
            has = true;
            value = tmp;
            return;
        }
    }
    if (fallback_suffix && gguf_get_u32_by_suffix(ctx, fallback_suffix, tmp)) {
        has = true;
        value = tmp;
    }
}

static void fill_gguf_metadata(const gguf_context * ctx,
                               const char * path,
                               const std::string & arch,
                               bool include_languages,
                               llama_engine_gguf_metadata & out) {
    out.version      = gguf_get_version(ctx);
    out.tensor_count = (uint64_t) gguf_get_n_tensors(ctx);
    out.file_size    = file_size_or_zero(path);

    fill_arch_u32(ctx, arch, ".block_count",     ".block_count",      out.has_block_count,      out.block_count);
    if (!out.has_block_count) {
        fill_arch_u32(ctx, arch, ".layer_count", ".layer_count",      out.has_block_count,      out.block_count);
    }
    fill_arch_u32(ctx, arch, ".embedding_length", ".embedding_length", out.has_embedding_length, out.embedding_length);
    if (!out.has_embedding_length) {
        fill_arch_u32(ctx, arch, ".embed_length", ".embed_length",    out.has_embedding_length, out.embedding_length);
    }
    fill_arch_u32(ctx, arch, ".context_length",  ".context_length",   out.has_context_length,   out.context_length);

    fill_arch_u32(ctx, arch, ".attention.head_count",       ".attention.head_count",       out.has_attention_head_count,       out.attention_head_count);
    fill_arch_u32(ctx, arch, ".attention.head_count_kv",    ".attention.head_count_kv",    out.has_attention_head_count_kv,    out.attention_head_count_kv);
    fill_arch_u32(ctx, arch, ".attention.key_length",       ".attention.key_length",       out.has_attention_key_length,       out.attention_key_length);
    fill_arch_u32(ctx, arch, ".attention.value_length",     ".attention.value_length",     out.has_attention_value_length,     out.attention_value_length);
    fill_arch_u32(ctx, arch, ".attention.sliding_window",   ".attention.sliding_window",   out.has_attention_sliding_window,   out.attention_sliding_window);
    fill_arch_u32(ctx, arch, ".attention.key_length_swa",   ".attention.key_length_swa",   out.has_attention_key_length_swa,   out.attention_key_length_swa);
    fill_arch_u32(ctx, arch, ".attention.value_length_swa", ".attention.value_length_swa", out.has_attention_value_length_swa, out.attention_value_length_swa);
    fill_arch_u32(ctx, arch, ".nextn_predict_layers",       ".nextn_predict_layers",       out.has_nextn_predict_layers,       out.nextn_predict_layers);
    fill_arch_u32(ctx, arch, ".attention.shared_kv_layers", ".attention.shared_kv_layers", out.has_attention_shared_kv_layers, out.attention_shared_kv_layers);

    uint32_t ftype = 0;
    if (gguf_get_u32(ctx, "general.file_type", ftype)) {
        out.has_file_type = true;
        out.file_type = ftype;
    }

    std::string tmp;
    if (gguf_get_str(ctx, "general.size_label", tmp)) {
        out.size_label = heap_str(tmp);
    }

    if (include_languages) {
        out.has_languages = gguf_get_str_array(ctx, "general.languages", &out.languages, &out.languages_count);
    }
}

// -----------------------------------------------------------------------------
// mmproj probe: read metadata and clip flags. No clip_init, no weights.
// -----------------------------------------------------------------------------

static llama_engine_status probe_mmproj(const char * mmproj_path,
                                        llama_engine_capabilities & caps,
                                        llama_engine_projector_info & projector,
                                        bool & has_projector,
                                        std::string & error)
{
    if (!mmproj_path || !*mmproj_path) {
        return LLAMA_ENGINE_OK; // nothing to do
    }

    gguf_init_params gp{};
    gp.no_alloc = true;
    gp.ctx     = nullptr;
    gguf_context * gctx = gguf_init_from_file(mmproj_path, gp);
    if (!gctx) {
        error = std::string("failed to read mmproj GGUF: ") + mmproj_path;
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }

    std::string arch;
    gguf_get_str(gctx, "general.architecture", arch);
    fill_gguf_metadata(gctx, mmproj_path, arch, /*include_languages=*/ false, projector.metadata);

    bool has_v = false, has_a = false;
    if (!gguf_get_bool_lenient(gctx, "clip.has_vision_encoder", has_v)) {
        gguf_get_bool_by_suffix(gctx, ".has_vision_encoder", has_v);
    }
    if (!gguf_get_bool_lenient(gctx, "clip.has_audio_encoder", has_a)) {
        gguf_get_bool_by_suffix(gctx, ".has_audio_encoder", has_a);
    }
    projector.has_vision_encoder = has_v;
    projector.has_audio_encoder  = has_a;

    std::string tmp;
    if (gguf_get_str_by_suffix(gctx, ".projector_type", tmp)) {
        projector.projector_type = heap_str(tmp);
    }

    uint32_t u32 = 0;
    if (gguf_get_u32_by_suffix(gctx, ".image_size", u32)) {
        projector.has_vision_image_size = true;
        projector.vision_image_size = u32;
    }
    if (gguf_get_u32_by_suffix(gctx, ".patch_size", u32)) {
        projector.has_vision_patch_size = true;
        projector.vision_patch_size = u32;
    }

    caps.has_mtmd        = true;
    caps.supports_vision = has_v;
    caps.supports_audio  = has_a;
    has_projector        = true;

    gguf_free(gctx);
    return LLAMA_ENGINE_OK;
}

// -----------------------------------------------------------------------------
// Chat-template-derived caps. Soft on all errors.
// -----------------------------------------------------------------------------

static void derive_chat_template_caps(const std::string & tmpl_src,
                                      llama_engine_capabilities & caps)
{
    if (tmpl_src.empty()) return;
    try {
        auto tmpls = common_chat_templates_init(/*model=*/ nullptr,
                                                tmpl_src,
                                                /*bos=*/ "",
                                                /*eos=*/ "");
        if (!tmpls) return;
        try {
            const auto map = common_chat_templates_get_caps(tmpls.get());
            const auto lookup = [&](const char * key) -> bool {
                auto it = map.find(key);
                return it != map.end() && it->second;
            };
            caps.supports_tool_calls         = lookup("supports_tool_calls");
            caps.supports_reasoning          = lookup("supports_reasoning");
            caps.supports_preserve_reasoning = lookup("supports_preserve_reasoning");
        } catch (const std::exception & e) {
            LOG_WRN("caps_probe: chat_templates_get_caps failed: %s\n", e.what());
        }
        if (caps.supports_reasoning) {
            try {
                caps.supports_reasoning_toggle = common_chat_templates_supports_reasoning_toggle(tmpls.get());
                caps.has_supports_reasoning_toggle = true;
            } catch (const std::exception & e) {
                LOG_WRN("caps_probe: reasoning toggle probe failed: %s\n", e.what());
            }
        }
    } catch (const std::exception & e) {
        LOG_WRN("caps_probe: chat_templates_init failed: %s\n", e.what());
    }
}

} // namespace

// -----------------------------------------------------------------------------
// Public probe entry point.
// -----------------------------------------------------------------------------

llama_engine_status probe_model_info(const char * model_path,
                                     const char * mmproj_path,
                                     llama_engine_model_info & out,
                                     std::string & error)
{
    out = llama_engine_model_info{};
    error.clear();

    if (!model_path || !*model_path) {
        error = "model_path is required";
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }

    // 1. Open the main model GGUF (metadata only).
    gguf_init_params gp{};
    gp.no_alloc = true;
    gp.ctx      = nullptr;
    gguf_context * gctx = gguf_init_from_file(model_path, gp);
    if (!gctx) {
        // Disambiguate: file missing vs invalid GGUF.
        FILE * f = std::fopen(model_path, "rb");
        if (!f) {
            error = std::string("model file not found or unreadable: ") + model_path;
        } else {
            std::fclose(f);
            error = std::string("invalid GGUF: ") + model_path;
        }
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }

    // 2. Architecture (composes the keys for ctx_length / nextn).
    std::string arch;
    gguf_get_str(gctx, "general.architecture", arch);

    // 3. Generic and display metadata (best-effort).
    fill_gguf_metadata(gctx, model_path, arch, /*include_languages=*/ true, out.metadata);

    std::string tmp;
    if (gguf_get_str(gctx, "general.name", tmp)) { out.name = heap_str(tmp); }

    if (out.metadata.has_file_type) {
        out.quantization = heap_str(ftype_label(out.metadata.file_type));
    }

    out.architecture = heap_str(arch); // empty string if absent (per contract).

    // 4. MTP capability: <arch>.nextn_predict_layers > 0.
    if (!arch.empty()) {
        uint32_t nextn = 0;
        const std::string nextn_key = arch + ".nextn_predict_layers";
        if (gguf_get_u32(gctx, nextn_key.c_str(), nextn) && nextn > 0) {
            out.capabilities.supports_mtp = true;
        }
    }

    // 5. Chat template -> tool_calls / reasoning / preserve_reasoning.
    {
        std::string tmpl_src;
        gguf_get_str(gctx, "tokenizer.chat_template", tmpl_src);
        derive_chat_template_caps(tmpl_src, out.capabilities);
    }

    gguf_free(gctx);

    // 6. mmproj (optional) -> projector metadata / has_mtmd / supports_vision / supports_audio.
    {
        std::string mmproj_err;
        const auto st = probe_mmproj(mmproj_path, out.capabilities, out.projector, out.has_projector, mmproj_err);
        if (st != LLAMA_ENGINE_OK) {
            // Hard error on the mmproj: roll back, free what we allocated.
            llama_engine_free_model_info(&out);
            error = std::move(mmproj_err);
            return st;
        }
    }

    return LLAMA_ENGINE_OK;
}

} // namespace llama_engine
