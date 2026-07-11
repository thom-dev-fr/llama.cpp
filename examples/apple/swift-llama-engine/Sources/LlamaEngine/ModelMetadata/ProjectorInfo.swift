import Foundation

/// Metadata specific to an optional multimodal projector GGUF.
///
/// This type is safe to persist. New fields must decode defensively so older
/// persisted snapshots keep loading.
public struct ProjectorInfo: Sendable, Hashable, Codable {
    /// Generic GGUF metadata for the projector file.
    public var metadata: GGUFFileInfo

    /// True if the projector advertises a vision encoder.
    public var hasVisionEncoder: Bool

    /// True if the projector advertises an audio encoder.
    public var hasAudioEncoder: Bool

    /// Projector implementation type (`mlp`, `resampler`, etc.). Nil if absent.
    public var projectorType: String?

    /// Vision image size if advertised by the projector metadata.
    public var visionImageSize: UInt32?

    /// Vision patch size if advertised by the projector metadata.
    public var visionPatchSize: UInt32?

    public init(metadata: GGUFFileInfo = GGUFFileInfo(),
                hasVisionEncoder: Bool = false,
                hasAudioEncoder: Bool = false,
                projectorType: String? = nil,
                visionImageSize: UInt32? = nil,
                visionPatchSize: UInt32? = nil) {
        self.metadata = metadata
        self.hasVisionEncoder = hasVisionEncoder
        self.hasAudioEncoder = hasAudioEncoder
        self.projectorType = projectorType
        self.visionImageSize = visionImageSize
        self.visionPatchSize = visionPatchSize
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case hasVisionEncoder
        case hasAudioEncoder
        case projectorType
        case visionImageSize
        case visionPatchSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            metadata:         try c.decodeIfPresent(GGUFFileInfo.self, forKey: .metadata) ?? GGUFFileInfo(),
            hasVisionEncoder: try c.decodeIfPresent(Bool.self, forKey: .hasVisionEncoder) ?? false,
            hasAudioEncoder:  try c.decodeIfPresent(Bool.self, forKey: .hasAudioEncoder) ?? false,
            projectorType:    try c.decodeIfPresent(String.self, forKey: .projectorType),
            visionImageSize:  try c.decodeIfPresent(UInt32.self, forKey: .visionImageSize),
            visionPatchSize:  try c.decodeIfPresent(UInt32.self, forKey: .visionPatchSize)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(hasVisionEncoder, forKey: .hasVisionEncoder)
        try c.encode(hasAudioEncoder, forKey: .hasAudioEncoder)
        try c.encodeIfPresent(projectorType, forKey: .projectorType)
        try c.encodeIfPresent(visionImageSize, forKey: .visionImageSize)
        try c.encodeIfPresent(visionPatchSize, forKey: .visionPatchSize)
    }
}

