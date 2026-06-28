import Foundation

/// Display-oriented and persistable metadata about a model file, returned
/// alongside its capabilities by `LlamaEngine.modelInfo(modelURL:mmprojURL:)`.
///
/// All non-required fields are best-effort: a missing GGUF key surfaces as
/// `nil` (or `""` for `architecture`), never a probe failure. This type is a
/// stable persistence contract for clients that cache probed GGUF metadata.
public struct ModelInfo: Sendable, Hashable, Codable {
    /// Capability flags derived from the same metadata pass.
    public var capabilities: ModelCapabilities

    /// Generic GGUF metadata for the main model file.
    public var metadata: GGUFFileInfo

    /// Optional multimodal projector info, present iff `mmprojURL` was supplied
    /// and opened as a valid GGUF.
    public var projector: ProjectorInfo?

    /// `general.architecture` (e.g. "llama", "qwen3", "deepseek2"). Empty
    /// string for the pathological case of a GGUF without that key.
    public var architecture: String

    /// `general.name`. Nil if absent.
    public var name: String?

    /// Decoded `general.file_type` (e.g. "Q4_K - Medium", "F16"). Nil if
    /// absent; typically only models that have been quantised carry this key.
    public var quantization: String?

    /// Backward-compatible alias for `metadata.sizeLabel`.
    public var sizeLabel: String? { metadata.sizeLabel }

    /// Backward-compatible alias for `metadata.contextLength`.
    public var contextLength: UInt32? { metadata.contextLength }

    /// Backward-compatible alias for `metadata.fileSize`.
    public var fileSize: UInt64 { metadata.fileSize }

    /// Preferred display quantization label.
    public var displayQuantizationName: String {
        quantization ?? metadata.quantizationName ?? "unknown, may not work"
    }

    /// True if the model advertises baked-in MTP heads.
    public var supportsMTP: Bool { capabilities.supportsMTP }

    public init(capabilities: ModelCapabilities = ModelCapabilities(),
                metadata: GGUFFileInfo = GGUFFileInfo(),
                projector: ProjectorInfo? = nil,
                architecture: String = "",
                name: String? = nil,
                quantization: String? = nil) {
        self.capabilities = capabilities
        self.metadata = metadata
        self.projector = projector
        self.architecture = architecture
        self.name = name
        self.quantization = quantization
    }

    /// Compatibility initializer matching the original display-only API.
    public init(capabilities: ModelCapabilities = ModelCapabilities(),
                architecture: String = "",
                name: String? = nil,
                sizeLabel: String? = nil,
                quantization: String? = nil,
                contextLength: UInt32? = nil,
                fileSize: UInt64 = 0) {
        self.init(
            capabilities: capabilities,
            metadata: GGUFFileInfo(
                contextLength: contextLength,
                sizeLabel: sizeLabel,
                fileSize: fileSize
            ),
            projector: nil,
            architecture: architecture,
            name: name,
            quantization: quantization
        )
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case metadata
        case projector
        case architecture
        case name
        case quantization
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capabilities: try c.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities) ?? ModelCapabilities(),
            metadata:     try c.decodeIfPresent(GGUFFileInfo.self, forKey: .metadata) ?? GGUFFileInfo(),
            projector:    try c.decodeIfPresent(ProjectorInfo.self, forKey: .projector),
            architecture: try c.decodeIfPresent(String.self, forKey: .architecture) ?? "",
            name:         try c.decodeIfPresent(String.self, forKey: .name),
            quantization: try c.decodeIfPresent(String.self, forKey: .quantization)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(metadata, forKey: .metadata)
        try c.encodeIfPresent(projector, forKey: .projector)
        try c.encode(architecture, forKey: .architecture)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(quantization, forKey: .quantization)
    }

    /// Metadata-only estimate from a full runtime config. This does not load
    /// model weights or initialise a llama context.
    public func estimatedMemoryUsage(config: ModelConfig) -> MemoryEstimate {
        estimatedMemoryUsage(parameters: MemoryEstimateParameters(config: config))
    }

    /// Metadata-only estimate. This intentionally estimates capacity pressure:
    /// model and projector files are counted even when runtime uses mmap.
    public func estimatedMemoryUsage(parameters: MemoryEstimateParameters) -> MemoryEstimate {
        MemoryEstimator.estimate(modelInfo: self, parameters: parameters)
    }
}
