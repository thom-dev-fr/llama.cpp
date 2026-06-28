import Foundation
import LlamaEngineCore

enum ModelInfoProbe {
    static func probe(modelURL: URL, mmprojURL: URL?) throws -> ModelInfo {
        let modelPath = modelURL.path
        let mmprojPath = mmprojURL?.path

        var cinfo = llama_engine_model_info()
        var errPtr: UnsafeMutablePointer<CChar>? = nil

        let status = modelPath.withCString { cModel -> llama_engine_status in
            if let mp = mmprojPath {
                return mp.withCString { cMmproj in
                    llama_engine_probe_model_info(cModel, cMmproj, &cinfo, &errPtr)
                }
            } else {
                return llama_engine_probe_model_info(cModel, nil, &cinfo, &errPtr)
            }
        }

        defer {
            llama_engine_free_model_info(&cinfo)
            llama_engine_free_string(errPtr)
        }

        if status != LLAMA_ENGINE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "probe failed"
            throw LlamaError.invalidArgument(msg)
        }

        let caps = ModelCapabilities(
            hasMultimodal:             cinfo.capabilities.has_mtmd,
            supportsVision:            cinfo.capabilities.supports_vision,
            supportsAudio:             cinfo.capabilities.supports_audio,
            supportsToolCalls:         cinfo.capabilities.supports_tool_calls,
            supportsReasoning:         cinfo.capabilities.supports_reasoning,
            supportsPreserveReasoning: cinfo.capabilities.supports_preserve_reasoning,
            supportsMTP:               cinfo.capabilities.supports_mtp
        )

        return ModelInfo(
            capabilities: caps,
            metadata: swiftGGUFFileInfo(cinfo.metadata),
            projector: cinfo.has_projector ? swiftProjectorInfo(cinfo.projector) : nil,
            architecture: cinfo.architecture.map { String(cString: $0) } ?? "",
            name: cinfo.name.map { String(cString: $0) },
            quantization: cinfo.quantization.map { String(cString: $0) }
        )
    }

    private static func swiftGGUFFileInfo(_ cmeta: llama_engine_gguf_metadata) -> GGUFFileInfo {
        let languages: [String]? = {
            guard cmeta.has_languages else { return nil }
            let count = Int(cmeta.languages_count)
            guard let base = cmeta.languages else { return [] }
            return (0..<count).compactMap { idx in
                base[idx].map { String(cString: $0) }
            }
        }()

        return GGUFFileInfo(
            version: cmeta.version,
            tensorCount: cmeta.tensor_count,
            blockCount: cmeta.has_block_count ? cmeta.block_count : nil,
            embeddingLength: cmeta.has_embedding_length ? cmeta.embedding_length : nil,
            contextLength: cmeta.has_context_length ? cmeta.context_length : nil,
            attentionHeadCount: optionalCMetaU32(cmeta, has: "has_attention_head_count", value: "attention_head_count"),
            attentionHeadCountKV: optionalCMetaU32(cmeta, has: "has_attention_head_count_kv", value: "attention_head_count_kv"),
            attentionKeyLength: optionalCMetaU32(cmeta, has: "has_attention_key_length", value: "attention_key_length"),
            attentionValueLength: optionalCMetaU32(cmeta, has: "has_attention_value_length", value: "attention_value_length"),
            attentionSlidingWindow: optionalCMetaU32(cmeta, has: "has_attention_sliding_window", value: "attention_sliding_window"),
            attentionKeyLengthSWA: optionalCMetaU32(cmeta, has: "has_attention_key_length_swa", value: "attention_key_length_swa"),
            attentionValueLengthSWA: optionalCMetaU32(cmeta, has: "has_attention_value_length_swa", value: "attention_value_length_swa"),
            nextnPredictLayers: optionalCMetaU32(cmeta, has: "has_nextn_predict_layers", value: "nextn_predict_layers"),
            attentionSharedKVLayers: optionalCMetaU32(cmeta, has: "has_attention_shared_kv_layers", value: "attention_shared_kv_layers"),
            fileType: cmeta.has_file_type ? cmeta.file_type : nil,
            sizeLabel: cmeta.size_label.map { String(cString: $0) },
            languages: languages,
            fileSize: cmeta.file_size
        )
    }

    private static func swiftProjectorInfo(_ cprojector: llama_engine_projector_info) -> ProjectorInfo {
        ProjectorInfo(
            metadata: swiftGGUFFileInfo(cprojector.metadata),
            hasVisionEncoder: cprojector.has_vision_encoder,
            hasAudioEncoder: cprojector.has_audio_encoder,
            projectorType: cprojector.projector_type.map { String(cString: $0) },
            visionImageSize: cprojector.has_vision_image_size ? cprojector.vision_image_size : nil,
            visionPatchSize: cprojector.has_vision_patch_size ? cprojector.vision_patch_size : nil
        )
    }

    private static func optionalCMetaU32(_ cmeta: llama_engine_gguf_metadata,
                                         has hasField: String,
                                         value valueField: String) -> UInt32? {
        var hasValue = false
        var value: UInt32?
        for child in Mirror(reflecting: cmeta).children {
            guard let label = child.label else { continue }
            if label == hasField, let b = child.value as? Bool {
                hasValue = b
            } else if label == valueField, let u = child.value as? UInt32 {
                value = u
            }
        }
        return hasValue ? value : nil
    }
}
