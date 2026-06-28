import Foundation

/// Generic metadata read from a GGUF file without loading tensor data.
///
/// This type is safe to persist. New fields must decode defensively so older
/// persisted snapshots keep loading.
public struct GGUFFileInfo: Sendable, Hashable, Codable {
    /// GGUF container version.
    public var version: UInt32

    /// Number of tensor descriptors in the file.
    public var tensorCount: UInt64

    /// `<arch>.block_count` / `<arch>.layer_count`. Nil if absent.
    public var blockCount: UInt32?

    /// `<arch>.embedding_length` / `<arch>.embed_length`. Nil if absent.
    public var embeddingLength: UInt32?

    /// `<arch>.context_length`. Nil if absent.
    public var contextLength: UInt32?

    /// `<arch>.attention.head_count`. Nil if absent. If the GGUF stores a
    /// per-layer array, this is the maximum value exposed by the metadata probe.
    public var attentionHeadCount: UInt32?

    /// `<arch>.attention.head_count_kv`. Nil if absent; defaults to
    /// `attentionHeadCount` for memory estimation.
    public var attentionHeadCountKV: UInt32?

    /// `<arch>.attention.key_length`. Nil if absent; defaults to
    /// `embeddingLength / attentionHeadCount` when possible.
    public var attentionKeyLength: UInt32?

    /// `<arch>.attention.value_length`. Nil if absent; defaults to
    /// `embeddingLength / attentionHeadCount` when possible.
    public var attentionValueLength: UInt32?

    /// `<arch>.attention.sliding_window`. Nil if absent.
    public var attentionSlidingWindow: UInt32?

    /// `<arch>.attention.key_length_swa`. Nil if absent.
    public var attentionKeyLengthSWA: UInt32?

    /// `<arch>.attention.value_length_swa`. Nil if absent.
    public var attentionValueLengthSWA: UInt32?

    /// `<arch>.nextn_predict_layers`. Nil if absent.
    public var nextnPredictLayers: UInt32?

    /// `<arch>.attention.shared_kv_layers`. Nil if absent.
    public var attentionSharedKVLayers: UInt32?

    /// Raw `general.file_type` enum value. Nil if absent.
    public var fileType: UInt32?

    /// `general.size_label` (e.g. "8B", "70B"). Nil if absent.
    public var sizeLabel: String?

    /// `general.languages`. Nil if absent.
    public var languages: [String]?

    /// Filesystem size in bytes. Zero only if `stat()` failed at probe time.
    public var fileSize: UInt64

    public init(version: UInt32 = 0,
                tensorCount: UInt64 = 0,
                blockCount: UInt32? = nil,
                embeddingLength: UInt32? = nil,
                contextLength: UInt32? = nil,
                attentionHeadCount: UInt32? = nil,
                attentionHeadCountKV: UInt32? = nil,
                attentionKeyLength: UInt32? = nil,
                attentionValueLength: UInt32? = nil,
                attentionSlidingWindow: UInt32? = nil,
                attentionKeyLengthSWA: UInt32? = nil,
                attentionValueLengthSWA: UInt32? = nil,
                nextnPredictLayers: UInt32? = nil,
                attentionSharedKVLayers: UInt32? = nil,
                fileType: UInt32? = nil,
                sizeLabel: String? = nil,
                languages: [String]? = nil,
                fileSize: UInt64 = 0) {
        self.version = version
        self.tensorCount = tensorCount
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
        self.contextLength = contextLength
        self.attentionHeadCount = attentionHeadCount
        self.attentionHeadCountKV = attentionHeadCountKV
        self.attentionKeyLength = attentionKeyLength
        self.attentionValueLength = attentionValueLength
        self.attentionSlidingWindow = attentionSlidingWindow
        self.attentionKeyLengthSWA = attentionKeyLengthSWA
        self.attentionValueLengthSWA = attentionValueLengthSWA
        self.nextnPredictLayers = nextnPredictLayers
        self.attentionSharedKVLayers = attentionSharedKVLayers
        self.fileType = fileType
        self.sizeLabel = sizeLabel
        self.languages = languages
        self.fileSize = fileSize
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tensorCount
        case blockCount
        case embeddingLength
        case contextLength
        case attentionHeadCount
        case attentionHeadCountKV
        case attentionKeyLength
        case attentionValueLength
        case attentionSlidingWindow
        case attentionKeyLengthSWA
        case attentionValueLengthSWA
        case nextnPredictLayers
        case attentionSharedKVLayers
        case fileType
        case sizeLabel
        case languages
        case fileSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version:         try c.decodeIfPresent(UInt32.self, forKey: .version) ?? 0,
            tensorCount:     try c.decodeIfPresent(UInt64.self, forKey: .tensorCount) ?? 0,
            blockCount:      try c.decodeIfPresent(UInt32.self, forKey: .blockCount),
            embeddingLength: try c.decodeIfPresent(UInt32.self, forKey: .embeddingLength),
            contextLength:              try c.decodeIfPresent(UInt32.self, forKey: .contextLength),
            attentionHeadCount:         try c.decodeIfPresent(UInt32.self, forKey: .attentionHeadCount),
            attentionHeadCountKV:       try c.decodeIfPresent(UInt32.self, forKey: .attentionHeadCountKV),
            attentionKeyLength:         try c.decodeIfPresent(UInt32.self, forKey: .attentionKeyLength),
            attentionValueLength:       try c.decodeIfPresent(UInt32.self, forKey: .attentionValueLength),
            attentionSlidingWindow:     try c.decodeIfPresent(UInt32.self, forKey: .attentionSlidingWindow),
            attentionKeyLengthSWA:      try c.decodeIfPresent(UInt32.self, forKey: .attentionKeyLengthSWA),
            attentionValueLengthSWA:    try c.decodeIfPresent(UInt32.self, forKey: .attentionValueLengthSWA),
            nextnPredictLayers:         try c.decodeIfPresent(UInt32.self, forKey: .nextnPredictLayers),
            attentionSharedKVLayers:    try c.decodeIfPresent(UInt32.self, forKey: .attentionSharedKVLayers),
            fileType:                   try c.decodeIfPresent(UInt32.self, forKey: .fileType),
            sizeLabel:                  try c.decodeIfPresent(String.self, forKey: .sizeLabel),
            languages:       try c.decodeIfPresent([String].self, forKey: .languages),
            fileSize:        try c.decodeIfPresent(UInt64.self, forKey: .fileSize) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(tensorCount, forKey: .tensorCount)
        try c.encodeIfPresent(blockCount, forKey: .blockCount)
        try c.encodeIfPresent(embeddingLength, forKey: .embeddingLength)
        try c.encodeIfPresent(contextLength, forKey: .contextLength)
        try c.encodeIfPresent(attentionHeadCount, forKey: .attentionHeadCount)
        try c.encodeIfPresent(attentionHeadCountKV, forKey: .attentionHeadCountKV)
        try c.encodeIfPresent(attentionKeyLength, forKey: .attentionKeyLength)
        try c.encodeIfPresent(attentionValueLength, forKey: .attentionValueLength)
        try c.encodeIfPresent(attentionSlidingWindow, forKey: .attentionSlidingWindow)
        try c.encodeIfPresent(attentionKeyLengthSWA, forKey: .attentionKeyLengthSWA)
        try c.encodeIfPresent(attentionValueLengthSWA, forKey: .attentionValueLengthSWA)
        try c.encodeIfPresent(nextnPredictLayers, forKey: .nextnPredictLayers)
        try c.encodeIfPresent(attentionSharedKVLayers, forKey: .attentionSharedKVLayers)
        try c.encodeIfPresent(fileType, forKey: .fileType)
        try c.encodeIfPresent(sizeLabel, forKey: .sizeLabel)
        try c.encodeIfPresent(languages, forKey: .languages)
        try c.encode(fileSize, forKey: .fileSize)
    }

    /// True when this metadata snapshot has the GGUF keys required for KV-cache
    /// memory estimation.
    public var hasMemoryEstimationInputs: Bool {
        blockCount != nil && embeddingLength != nil
    }

    /// Quantization label decoded from `general.file_type`, aligned with
    /// llama.cpp's `llama_model_ftype_name()` mapping. Nil if `fileType` is nil.
    public var quantizationName: String? {
        fileType.map(Self.quantizationName(for:))
    }

    /// Quantization label for a raw `general.file_type` enum value.
    public static func quantizationName(for fileType: UInt32) -> String {
        // Keep in sync with engine/src/caps_probe.cpp's ftype_label().
        let guessed: UInt32 = 1024 // LLAMA_FTYPE_GUESSED
        switch fileType & ~guessed {
        case 0:  return "all F32"
        case 1:  return "F16"
        case 2:  return "Q4_0"
        case 3:  return "Q4_1"
        case 7:  return "Q8_0"
        case 8:  return "Q5_0"
        case 9:  return "Q5_1"
        case 10: return "Q2_K - Medium"
        case 11: return "Q3_K - Small"
        case 12: return "Q3_K - Medium"
        case 13: return "Q3_K - Large"
        case 14: return "Q4_K - Small"
        case 15: return "Q4_K - Medium"
        case 16: return "Q5_K - Small"
        case 17: return "Q5_K - Medium"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS - 2.0625 bpw"
        case 20: return "IQ2_XS - 2.3125 bpw"
        case 21: return "Q2_K - Small"
        case 22: return "IQ3_XS - 3.3 bpw"
        case 23: return "IQ3_XXS - 3.0625 bpw"
        case 24: return "IQ1_S - 1.5625 bpw"
        case 25: return "IQ4_NL - 4.5 bpw"
        case 26: return "IQ3_S - 3.4375 bpw"
        case 27: return "IQ3_S mix - 3.66 bpw"
        case 28: return "IQ2_S - 2.5 bpw"
        case 29: return "IQ2_M - 2.7 bpw"
        case 30: return "IQ4_XS - 4.25 bpw"
        case 31: return "IQ1_M - 1.75 bpw"
        case 32: return "BF16"
        case 36: return "TQ1_0 - 1.69 bpw ternary"
        case 37: return "TQ2_0 - 2.06 bpw ternary"
        case 38: return "MXFP4 MoE"
        case 39: return "Q1_0"
        case 40: return "NVFP4"
        default: return "unknown, may not work"
        }
    }
}

