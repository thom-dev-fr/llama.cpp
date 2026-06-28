import Foundation

public struct ModelConfig: Sendable {
    public enum KVCacheType: Int32, Sendable, Hashable, Codable {
        case f32    = 0
        case f16    = 1
        case bf16   = 2
        case q8_0   = 3
        case q4_0   = 4
        case q5_0   = 5
        case iq4_nl = 6

        /// Approximate per-element size in bytes for coarse UI display.
        /// Precise cache estimates use `estimatedRowBytes(elementCount:)`.
        public var estimatedBytesPerElement: Int {
            switch self {
            case .f32: return 4
            case .f16, .bf16: return 2
            case .q8_0: return 1
            case .q5_0, .q4_0, .iq4_nl: return 1
            }
        }

        /// Metadata-only equivalent of `ggml_row_size(type, elementCount)` for
        /// the KV-cache types exposed by the engine.
        public func estimatedRowBytes(elementCount: UInt64) -> UInt64 {
            switch self {
            case .f32:  return elementCount * 4
            case .f16, .bf16: return elementCount * 2
            case .q8_0: return Self.blocks(elementCount, blockSize: 32) * 34
            case .q5_0: return Self.blocks(elementCount, blockSize: 32) * 22
            case .q4_0, .iq4_nl: return Self.blocks(elementCount, blockSize: 32) * 18
            }
        }

        private static func blocks(_ elementCount: UInt64, blockSize: UInt64) -> UInt64 {
            (elementCount + blockSize - 1) / blockSize
        }
    }

    public var modelPath: URL
    public var contextSize: Int32          = 0      // 0 => engine default
    public var gpuLayers: Int32            = -1     // -1 => all
    public var parallelSlots: Int32        = 1
    public var cpuThreads: Int32           = 0      // 0 => auto
    public var seed: UInt32                = 0xFFFF_FFFF
    /// Optional path to a multimodal projector (mmproj GGUF). When set,
    /// enables `image_url` / `input_audio` content parts in chat requests.
    /// Pass `nil` for text-only models.
    public var mtmdProjectorPath: URL?     = nil
    public var chatTemplateOverride: String? = nil
    public var useMMap: Bool               = true
    public var useMlock: Bool              = false
    public var flashAttention: Bool        = false
    public var kvCacheType: KVCacheType    = .f16
    public var idlePauseSeconds: Int32     = -1     // -1 => disabled
    /// Enable Multi-Token Prediction speculative decoding (`--spec-type draft-mtp`).
    /// Two modes:
    /// - **self-MTP**: leave `mtpDraftModelPath` nil and load a model whose
    ///   GGUF embeds an MTP head. The engine spawns a second context over
    ///   the target model with `LLAMA_CONTEXT_TYPE_MTP`.
    /// - **external draft head**: set `mtpDraftModelPath` to a sibling
    ///   `mtp-*.gguf` file. It is loaded as the draft model.
    /// Drafting knobs (`n_max`, `n_min`, `p_min`, `p_split`) can be tuned
    /// through `extraJSON`, e.g. `{"mtp": {"n_max": 4, "p_min": 0.0}}`.
    /// MTP cannot be combined with other speculative types — when this is
    /// `true` the engine sets `speculative.types = [DRAFT_MTP]`.
    public var enableMTP: Bool             = false
    public var mtpDraftModelPath: URL?     = nil
    /// Escape hatch: JSON object merged into the underlying common_params.
    /// Only a whitelist of keys is honoured (see ParamsTranslator::apply_extra_json).
    public var extraJSON: String?          = nil

    public init(
        modelPath: URL,
        contextSize: Int32 = 0,
        gpuLayers: Int32 = -1,
        parallelSlots: Int32 = 1,
        cpuThreads: Int32 = 0,
        seed: UInt32 = 0xFFFF_FFFF,
        mtmdProjectorPath: URL? = nil,
        chatTemplateOverride: String? = nil,
        useMMap: Bool = true,
        useMlock: Bool = false,
        flashAttention: Bool = false,
        kvCacheType: KVCacheType = .f16,
        idlePauseSeconds: Int32 = -1,
        enableMTP: Bool = false,
        mtpDraftModelPath: URL? = nil,
        extraJSON: String? = nil
    ) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.parallelSlots = parallelSlots
        self.cpuThreads = cpuThreads
        self.seed = seed
        self.mtmdProjectorPath = mtmdProjectorPath
        self.chatTemplateOverride = chatTemplateOverride
        self.useMMap = useMMap
        self.useMlock = useMlock
        self.flashAttention = flashAttention
        self.kvCacheType = kvCacheType
        self.idlePauseSeconds = idlePauseSeconds
        self.enableMTP = enableMTP
        self.mtpDraftModelPath = mtpDraftModelPath
        self.extraJSON = extraJSON
    }
}

public enum LogLevel: Int32, Sendable {
    case off     = 0
    case error   = 1
    case warning = 2
    case info    = 3
    case debug   = 4
}
