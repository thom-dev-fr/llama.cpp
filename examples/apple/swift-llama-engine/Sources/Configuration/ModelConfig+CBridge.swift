import Foundation
import LlamaEngineCore

extension ModelConfig {
    /// Convert to a `llama_engine_config` with all C strings kept alive for the
    /// duration of `body`.
    func withCConfig<R>(_ body: (inout llama_engine_config) -> R) -> R {
        let path = modelPath.path
        let mtmd = mtmdProjectorPath?.path
        let tmpl = chatTemplateOverride
        let mtpDraft = mtpDraftModelPath?.path
        let extra = extraJSON

        return path.withCString { cPath in
            return (mtmd ?? "").withCString { cMtmd in
                return (tmpl ?? "").withCString { cTmpl in
                    return (mtpDraft ?? "").withCString { cMtpDraft in
                        return (extra ?? "").withCString { cExtra in
                            var cfg = llama_engine_config(
                                model_path: cPath,
                                context_size: contextSize,
                                gpu_layers: gpuLayers,
                                parallel_slots: parallelSlots,
                                cpu_threads: cpuThreads,
                                seed: seed,
                                mtmd_projector_path: (mtmd?.isEmpty == false) ? cMtmd : nil,
                                chat_template_override: (tmpl?.isEmpty == false) ? cTmpl : nil,
                                use_mmap: useMMap,
                                use_mlock: useMlock,
                                flash_attention: flashAttention,
                                kv_cache_type: llama_engine_kv_type(UInt32(kvCacheType.rawValue)),
                                idle_pause_seconds: idlePauseSeconds,
                                enable_mtp: enableMTP,
                                mtp_draft_model_path: (mtpDraft?.isEmpty == false) ? cMtpDraft : nil,
                                extra_json: (extra?.isEmpty == false) ? cExtra : nil
                            )
                            return body(&cfg)
                        }
                    }
                }
            }
        }
    }
}
