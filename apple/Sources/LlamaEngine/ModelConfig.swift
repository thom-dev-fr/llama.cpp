import Foundation

public struct ModelConfig: Sendable {
    public enum KVCacheType: Int32, Sendable {
        case f32    = 0
        case f16    = 1
        case bf16   = 2
        case q8_0   = 3
        case q4_0   = 4
        case q5_0   = 5
        case iq4_nl = 6
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
