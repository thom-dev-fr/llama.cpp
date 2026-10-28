#include "memory_measure.hpp"

#include "engine_core.hpp"
#include "params_translator.hpp"

#include "ggml.h"
#include "llama.h"

#include <algorithm>
#include <mutex>
#include <stdexcept>

namespace llama_engine {

using json = common_json;

static const char * row_kind_name(common_memory_breakdown_row::kind_t kind) {
    switch (kind) {
        case common_memory_breakdown_row::DEVICE:      return "device";
        case common_memory_breakdown_row::HOST:        return "host";
        case common_memory_breakdown_row::BUFFER_TYPE: return "buffer_type";
    }
    return "unknown";
}

static const char * flash_attn_name(llama_flash_attn_type type) {
    switch (type) {
        case LLAMA_FLASH_ATTN_TYPE_AUTO:     return "auto";
        case LLAMA_FLASH_ATTN_TYPE_DISABLED: return "disabled";
        case LLAMA_FLASH_ATTN_TYPE_ENABLED:  return "enabled";
    }
    return "unknown";
}

json memory_measure::report(const common_params & params,
                            const llama_model_params & mparams,
                            const llama_context_params & cparams,
                            const measured & m)
{
    // rows do not overlap: a buffer type is counted once, in its device, the host or its own row
    uint64_t model   = 0;
    uint64_t context = 0;
    uint64_t compute = 0;

    json rows = json::array();
    for (const auto & r : m.rows) {
        json row = {
            { "kind",          row_kind_name(r.kind)  },
            { "name",          r.name                 },
            { "model_bytes",   (uint64_t) r.model     },
            { "context_bytes", (uint64_t) r.context   },
            { "compute_bytes", (uint64_t) r.compute   },
        };
        if (!r.description.empty()) {
            row["description"] = r.description;
        }
        // device capacity is informative only, it is never added to the requirement
        if (r.kind == common_memory_breakdown_row::DEVICE && r.total > 0) {
            row["device_total_bytes"] = (uint64_t) r.total;
            row["device_free_bytes"]  = (uint64_t) std::max<int64_t>(r.free, 0);
        }
        rows.push_back(row);

        model   += r.model;
        context += r.context;
        compute += r.compute;
    }

    const bool has_projector = !params.mmproj.path.empty();
    const bool has_mtp       = std::find(params.speculative.types.begin(), params.speculative.types.end(),
                                         COMMON_SPECULATIVE_TYPE_DRAFT_MTP) != params.speculative.types.end();

    json warnings = json::array();
    if (has_projector) {
        warnings.push_back("the multimodal projector is not measured");
    }
    if (has_mtp) {
        warnings.push_back("the MTP draft context and an external draft model are not measured");
    }
    if (params.fit_params) {
        warnings.push_back("the load path fits unset parameters (context_size=0, gpu_layers=-1) to the free memory at load time, the loaded values can be lower than the measured ones");
    }
    warnings.push_back("compute bytes come from a no_alloc reservation and can be larger than the buffers of a loaded context");
    warnings.push_back("free device memory can change between this measurement and a load");

    return json {
        { "schema_version", schema_version },
        { "source",         "native"       },
        { "effective", {
            { "n_ctx",           m.n_ctx                               },
            { "n_ctx_train",     m.n_ctx_train                         },
            { "n_batch",         cparams.n_batch                       },
            { "n_ubatch",        cparams.n_ubatch                      },
            { "n_seq_max",       cparams.n_seq_max                     },
            { "kv_unified",      cparams.kv_unified                    },
            { "type_k",          ggml_type_name(cparams.type_k)        },
            { "type_v",          ggml_type_name(cparams.type_v)        },
            { "flash_attention", flash_attn_name(cparams.flash_attn_type) },
            { "gpu_layers",      mparams.n_gpu_layers                  },
        }},
        { "rows", rows },
        { "required_bytes", {
            { "model",   model                     },
            { "context", context                   },
            { "compute", compute                   },
            { "total",   model + context + compute },
        }},
        { "coverage", {
            { "model",     true           },
            { "context",   true           },
            { "projector", !has_projector },
            { "mtp_draft", !has_mtp       },
        }},
        { "complete", !has_projector && !has_mtp },
        { "warnings", warnings },
    };
}

llama_engine_status memory_measure::measure(const llama_engine_config & cfg,
                                            std::string &               out_json,
                                            std::string &               error)
{
    out_json.clear();
    error.clear();

    common_params params;
    try {
        params = params_translator::translate(cfg);
    } catch (const std::exception & e) {
        error = std::string("invalid config: ") + e.what();
        return LLAMA_ENGINE_ERR_INVALID_ARG;
    }

    engine_core::ensure_backend_initialized();

    // same conversion as common_init_from_params() in the load path, without --fit
    auto mparams = common_model_params_to_llama(params);
    auto cparams = common_context_params_to_llama(params);

    measured m;
    {
        static std::mutex measure_mtx;
        std::lock_guard<std::mutex> lock(measure_mtx);
        try {
            m.rows = common_fit_measure(params.model.path.c_str(), &mparams, &cparams,
                                        &m.n_ctx_train, &m.n_ctx, GGML_LOG_LEVEL_ERROR);
        } catch (const std::exception & e) {
            error = std::string("memory measurement failed: ") + e.what();
            return LLAMA_ENGINE_ERR_LOAD_FAILED;
        }
    }

    out_json = report(params, mparams, cparams, m).dump();
    return LLAMA_ENGINE_OK;
}

} // namespace llama_engine
