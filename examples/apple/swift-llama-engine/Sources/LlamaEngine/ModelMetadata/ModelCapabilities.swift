import Foundation

/// Intrinsic capabilities of a model file (and optionally its mmproj projector),
/// as reported by `LlamaEngine.modelInfo(modelURL:mmprojURL:)`.
///
/// This type is safe to persist. New fields must decode defensively so older
/// persisted snapshots keep loading.
public struct ModelCapabilities: Sendable, Hashable, Codable {
    /// True iff a non-nil `mmprojURL` was passed to the probe and the file
    /// could be opened as a valid GGUF.
    public var hasMultimodal: Bool

    /// True if the mmproj advertises a vision encoder
    /// (`clip.has_vision_encoder == true`).
    public var supportsVision: Bool

    /// True if the mmproj advertises an audio encoder
    /// (`clip.has_audio_encoder == true`).
    public var supportsAudio: Bool

    /// True if the GGUF-embedded chat template advertises tool-call rendering
    /// (jinja caps `supports_tool_calls`).
    public var supportsToolCalls: Bool

    /// True if the chat template can emit reasoning ("thinking") output, i.e.
    /// `common_chat_templates_support_enable_thinking()` succeeds. Covers
    /// Gemma, Ministral, Qwen3, DeepSeek-R1 distills, gpt-oss, GLM, etc.
    public var supportsReasoning: Bool

    /// True if the chat template re-injects a prior assistant
    /// `reasoning_content` field into the rendered prompt on the next turn.
    /// Rare (Qwen3 recent, GLM-4.5, gpt-oss, DeepSeek-V3.1). Most
    /// reasoning-capable models are `supportsReasoning == true` but
    /// `supportsPreserveReasoning == false`: drop `reasoning_content` from
    /// history before re-rendering the prompt.
    public var supportsPreserveReasoning: Bool

    /// True if the model has Multi-Token Prediction heads baked in
    /// (`<arch>.nextn_predict_layers > 0`). This is a capability; whether MTP
    /// is actually wired up at runtime is reported by `LlamaEngine.isMTPActive`.
    public var supportsMTP: Bool

    public init(hasMultimodal: Bool = false,
                supportsVision: Bool = false,
                supportsAudio: Bool = false,
                supportsToolCalls: Bool = false,
                supportsReasoning: Bool = false,
                supportsPreserveReasoning: Bool = false,
                supportsMTP: Bool = false) {
        self.hasMultimodal             = hasMultimodal
        self.supportsVision            = supportsVision
        self.supportsAudio             = supportsAudio
        self.supportsToolCalls         = supportsToolCalls
        self.supportsReasoning         = supportsReasoning
        self.supportsPreserveReasoning = supportsPreserveReasoning
        self.supportsMTP               = supportsMTP
    }

    private enum CodingKeys: String, CodingKey {
        case hasMultimodal
        case supportsVision
        case supportsAudio
        case supportsToolCalls
        case supportsReasoning
        case supportsPreserveReasoning
        case supportsMTP
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hasMultimodal:             try c.decodeIfPresent(Bool.self, forKey: .hasMultimodal) ?? false,
            supportsVision:            try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false,
            supportsAudio:             try c.decodeIfPresent(Bool.self, forKey: .supportsAudio) ?? false,
            supportsToolCalls:         try c.decodeIfPresent(Bool.self, forKey: .supportsToolCalls) ?? false,
            supportsReasoning:         try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false,
            supportsPreserveReasoning: try c.decodeIfPresent(Bool.self, forKey: .supportsPreserveReasoning) ?? false,
            supportsMTP:               try c.decodeIfPresent(Bool.self, forKey: .supportsMTP) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hasMultimodal, forKey: .hasMultimodal)
        try c.encode(supportsVision, forKey: .supportsVision)
        try c.encode(supportsAudio, forKey: .supportsAudio)
        try c.encode(supportsToolCalls, forKey: .supportsToolCalls)
        try c.encode(supportsReasoning, forKey: .supportsReasoning)
        try c.encode(supportsPreserveReasoning, forKey: .supportsPreserveReasoning)
        try c.encode(supportsMTP, forKey: .supportsMTP)
    }

    /// Returns true as soon as any feature flag is set.
    public var hasAnyCapability: Bool {
        hasMultimodal || supportsVision || supportsAudio
            || supportsToolCalls || supportsReasoning
            || supportsPreserveReasoning || supportsMTP
    }
}

