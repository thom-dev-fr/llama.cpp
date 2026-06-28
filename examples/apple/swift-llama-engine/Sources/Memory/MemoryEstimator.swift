import Foundation

enum MemoryEstimator {
    static func estimate(modelInfo: ModelInfo, parameters: MemoryEstimateParameters) -> MemoryEstimate {
        var warnings: [String] = []
        var confidence: MemoryEstimateConfidence = .high
        let metadata = modelInfo.metadata

        let contextCells = effectiveContextCells(
            requestedContextSize: parameters.contextSize,
            metadataContextSize: metadata.contextLength,
            parallelSlots: parameters.parallelSlots,
            warnings: &warnings,
            confidence: &confidence
        )

        let projectorBytes = parameters.includeProjector ? (modelInfo.projector?.metadata.fileSize ?? 0) : 0
        let kvBytes = estimateKVCacheBytes(
            metadata: metadata,
            contextCells: contextCells,
            kvCacheType: parameters.kvCacheType,
            flashAttention: parameters.flashAttention,
            warnings: &warnings,
            confidence: &confidence
        )

        let mtpBytes: UInt64 = {
            guard parameters.enableMTP && modelInfo.capabilities.supportsMTP else { return 0 }
            guard (metadata.nextnPredictLayers ?? 0) > 0 else {
                warnings.append("MTP requested but nextn_predict_layers is missing; using a small heuristic MTP overhead.")
                confidence = lower(confidence, to: .medium)
                return max(kvBytes / 20, 16 * 1024 * 1024)
            }
            return estimateMTPBytes(
                metadata: metadata,
                contextCells: contextCells,
                kvCacheType: parameters.kvCacheType,
                draftNMax: parameters.mtpDraftNMax,
                warnings: &warnings,
                confidence: &confidence
            )
        }()

        let persistent = metadata.fileSize + projectorBytes + kvBytes + mtpBytes
        let runtimeOverhead = estimateRuntimeOverheadBytes(
            persistentBytes: persistent,
            projectorBytes: projectorBytes,
            hasMTP: mtpBytes > 0
        )

        return MemoryEstimate(
            modelBytes: metadata.fileSize,
            projectorBytes: projectorBytes,
            kvCacheBytes: kvBytes,
            mtpBytes: mtpBytes,
            runtimeOverheadBytes: runtimeOverhead,
            effectiveContextSize: contextCells,
            confidence: confidence,
            warnings: warnings
        )
    }

    private static func effectiveContextCells(requestedContextSize: Int,
                                              metadataContextSize: UInt32?,
                                              parallelSlots: Int,
                                              warnings: inout [String],
                                              confidence: inout MemoryEstimateConfidence) -> UInt32 {
        let requested: UInt64
        if requestedContextSize > 0 {
            requested = UInt64(requestedContextSize)
        } else if let metadataContextSize, metadataContextSize > 0 {
            requested = UInt64(metadataContextSize)
        } else {
            requested = 4096
            warnings.append("contextSize is 0 and GGUF context_length is missing; using 4096 tokens.")
            confidence = lower(confidence, to: .low)
        }

        let padded = pad(requested, multiple: 256)
        let slots = UInt64(max(1, parallelSlots))
        guard slots > 1 else { return UInt32(clamping: padded) }

        let perSlot = pad(padded / slots, multiple: 256)
        return UInt32(clamping: perSlot * slots)
    }

    private static func estimateKVCacheBytes(metadata: GGUFFileInfo,
                                             contextCells: UInt32,
                                             kvCacheType: ModelConfig.KVCacheType,
                                             flashAttention: Bool,
                                             warnings: inout [String],
                                             confidence: inout MemoryEstimateConfidence) -> UInt64 {
        guard let layerCount = metadata.blockCount, layerCount > 0 else {
            warnings.append("block_count is missing; KV cache could not be estimated.")
            confidence = lower(confidence, to: .low)
            return 0
        }

        let targetLayers = layerCount - min(layerCount, metadata.nextnPredictLayers ?? 0)
        if (metadata.nextnPredictLayers ?? 0) > 0 {
            confidence = lower(confidence, to: .medium)
            warnings.append("Model has MTP layers; target KV layers were adjusted metadata-only.")
        }
        if metadata.attentionSharedKVLayers != nil {
            confidence = lower(confidence, to: .medium)
            warnings.append("Shared KV layers detected; estimator keeps a conservative layer-count approximation.")
        }

        guard let dims = attentionDimensions(metadata: metadata, warnings: &warnings, confidence: &confidence) else {
            guard let embedding = metadata.embeddingLength else {
                warnings.append("attention dimensions and embedding_length are missing; KV cache could not be estimated.")
                confidence = lower(confidence, to: .low)
                return 0
            }
            confidence = lower(confidence, to: .medium)
            return UInt64(2) * UInt64(targetLayers) * UInt64(embedding) * UInt64(contextCells) * UInt64(kvCacheType.estimatedBytesPerElement)
        }

        if metadata.attentionSlidingWindow != nil {
            confidence = lower(confidence, to: .medium)
            warnings.append("Sliding-window/SWA model detected; estimator keeps a conservative full-context KV approximation.")
        }
        if !flashAttention && dims.vWasVariableFallback {
            warnings.append("V-cache dimension may be padded when flash attention is disabled; using conservative dimension.")
            confidence = lower(confidence, to: .medium)
        }

        let kPerLayer = kvCacheType.estimatedRowBytes(elementCount: UInt64(dims.key)) * UInt64(contextCells)
        let vPerLayer = kvCacheType.estimatedRowBytes(elementCount: UInt64(dims.value)) * UInt64(contextCells)
        return UInt64(targetLayers) * (kPerLayer + vPerLayer)
    }

    private static func estimateMTPBytes(metadata: GGUFFileInfo,
                                         contextCells: UInt32,
                                         kvCacheType: ModelConfig.KVCacheType,
                                         draftNMax: Int,
                                         warnings: inout [String],
                                         confidence: inout MemoryEstimateConfidence) -> UInt64 {
        guard let nMTP = metadata.nextnPredictLayers, nMTP > 0,
              let dims = attentionDimensions(metadata: metadata, warnings: &warnings, confidence: &confidence) else {
            confidence = lower(confidence, to: .medium)
            return max(UInt64(draftNMax) * 16 * 1024 * 1024, 16 * 1024 * 1024)
        }

        // Bound the draft context by the main context to avoid underestimating
        // unusual configs.
        let mtpCells = min(contextCells, UInt32(clamping: max(256, draftNMax * 256)))
        let kPerLayer = kvCacheType.estimatedRowBytes(elementCount: UInt64(dims.key)) * UInt64(mtpCells)
        let vPerLayer = kvCacheType.estimatedRowBytes(elementCount: UInt64(dims.value)) * UInt64(mtpCells)
        confidence = lower(confidence, to: .medium)
        warnings.append("MTP memory is estimated from nextn_predict_layers and draft length; runtime graph buffers may differ.")
        return UInt64(nMTP) * (kPerLayer + vPerLayer)
    }

    private static func attentionDimensions(metadata: GGUFFileInfo,
                                            warnings: inout [String],
                                            confidence: inout MemoryEstimateConfidence) -> (key: UInt32, value: UInt32, vWasVariableFallback: Bool)? {
        let headCount = metadata.attentionHeadCount
        let headCountKV = metadata.attentionHeadCountKV ?? headCount

        let keyLength = metadata.attentionKeyLength ?? {
            guard let emb = metadata.embeddingLength, let hc = headCount, hc > 0 else { return nil }
            confidence = lower(confidence, to: .medium)
            warnings.append("attention.key_length missing; deriving it from embedding_length / head_count.")
            return emb / hc
        }()

        let valueLength = metadata.attentionValueLength ?? {
            guard let emb = metadata.embeddingLength, let hc = headCount, hc > 0 else { return nil }
            confidence = lower(confidence, to: .medium)
            warnings.append("attention.value_length missing; deriving it from embedding_length / head_count.")
            return emb / hc
        }()

        guard let hkv = headCountKV, hkv > 0, let k = keyLength, let v = valueLength else { return nil }
        return (key: hkv * k, value: hkv * v, vWasVariableFallback: false)
    }

    private static func estimateRuntimeOverheadBytes(persistentBytes: UInt64,
                                                     projectorBytes: UInt64,
                                                     hasMTP: Bool) -> UInt64 {
        let mib: UInt64 = 1024 * 1024
        let base = max(128 * mib, persistentBytes / 10)
        let projector = projectorBytes > 0 ? max(64 * mib, projectorBytes / 8) : 0
        let mtp = hasMTP ? 128 * mib : 0
        return min(base + projector + mtp, 2 * 1024 * mib)
    }

    private static func pad(_ value: UInt64, multiple: UInt64) -> UInt64 {
        guard multiple > 0 else { return value }
        return ((value + multiple - 1) / multiple) * multiple
    }

    private static func lower(_ confidence: MemoryEstimateConfidence,
                              to candidate: MemoryEstimateConfidence) -> MemoryEstimateConfidence {
        func rank(_ c: MemoryEstimateConfidence) -> Int {
            switch c {
            case .high: return 2
            case .medium: return 1
            case .low: return 0
            }
        }
        return rank(candidate) < rank(confidence) ? candidate : confidence
    }
}
