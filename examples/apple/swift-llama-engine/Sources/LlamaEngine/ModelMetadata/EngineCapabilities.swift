import Foundation

/// Capabilities of an engine configuration, decoded from the JSON document of
/// `llama_engine_probe_chat_capabilities()` or `llama_engine_get_capabilities()`.
///
/// Use ``LlamaEngine/chatCapabilities(for:)`` before loading a configuration,
/// and ``LlamaEngine/capabilities()`` to confirm the configuration that is
/// actually loaded. Unlike ``ModelCapabilities``, which comes from the
/// lightweight GGUF probe, this snapshot follows the template selection of the
/// load path, including `chatTemplateOverride`.
///
/// Every field decodes defensively: an absent value stays `nil`, which means
/// unknown, never `false`. ``rawJSON`` keeps the full document so fields added
/// by later engine versions are not lost.
public struct EngineCapabilities: Sendable, Hashable {
    /// The version of the JSON document.
    public var schemaVersion: Int

    /// Capabilities of the effective chat template, `nil` when the template
    /// could not be analysed.
    public var chatTemplate: ChatTemplateCapabilities?

    /// Why ``chatTemplate`` is `nil`, when the engine reported a reason.
    public var chatTemplateError: String?

    /// What the loaded model, projector and build can do. Only in the
    /// snapshot of a loaded engine, `nil` before loading.
    public var modelCapabilities: RuntimeModelCapabilities?

    /// What the engine API can run with the loaded configuration. Only in the
    /// snapshot of a loaded engine, `nil` before loading. Check this, not
    /// ``modelCapabilities``, before offering a feature.
    public var engineOperations: EngineOperations?

    /// The JSON document as returned by the engine.
    public var rawJSON: String

    public init(schemaVersion: Int = 1,
                chatTemplate: ChatTemplateCapabilities? = nil,
                chatTemplateError: String? = nil,
                modelCapabilities: RuntimeModelCapabilities? = nil,
                engineOperations: EngineOperations? = nil,
                rawJSON: String = "{}") {
        self.schemaVersion = schemaVersion
        self.chatTemplate = chatTemplate
        self.chatTemplateError = chatTemplateError
        self.modelCapabilities = modelCapabilities
        self.engineOperations = engineOperations
        self.rawJSON = rawJSON
    }

    /// Decodes an engine capabilities document.
    ///
    /// - Parameter json: The JSON document returned by the engine.
    public init(json: String) throws {
        let document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        self.init(
            schemaVersion: document.schemaVersion ?? 0,
            chatTemplate: document.chatTemplate,
            chatTemplateError: document.chatTemplateError,
            modelCapabilities: document.modelCapabilities,
            engineOperations: document.engineOperations,
            rawJSON: json
        )
    }

    private struct Document: Decodable {
        var schemaVersion: Int?
        var chatTemplate: ChatTemplateCapabilities?
        var chatTemplateError: String?
        var modelCapabilities: RuntimeModelCapabilities?
        var engineOperations: EngineOperations?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case chatTemplate = "chat_template"
            case chatTemplateError = "chat_template_error"
            case modelCapabilities = "model_capabilities"
            case engineOperations = "engine_operations"
        }
    }
}

/// Capabilities detected from the effective chat template.
///
/// Detection renders the template with probe inputs: it is a heuristic, not a
/// guarantee of model behaviour.
public struct ChatTemplateCapabilities: Sendable, Hashable, Codable {
    /// Where the template comes from: `"gguf"` (embedded, including the
    /// built-in fallback) or `"override"` (`chatTemplateOverride`).
    public var source: String?

    public var supportsToolCalls: Bool?
    public var supportsParallelToolCalls: Bool?
    public var supportsSystemRole: Bool?
    public var supportsReasoning: Bool?

    /// Whether conventional reasoning inputs turn reasoning on and off. `nil`
    /// means the analysis could not decide.
    public var supportsReasoningToggle: Bool?

    public var supportsPreserveReasoning: Bool?
    public var supportsReasoningEffort: Bool?

    /// Reasoning-effort values that render differently with this template,
    /// for example `["low", "medium", "high"]`. Aliases are folded into the
    /// highest level. `nil` means unknown; an empty array means the analysis
    /// ran and found no distinct level, not that the model cannot reason.
    /// Values unknown to this version of the package are kept as is.
    public var reasoningEffortLevels: [String]?

    public init(source: String? = nil,
                supportsToolCalls: Bool? = nil,
                supportsParallelToolCalls: Bool? = nil,
                supportsSystemRole: Bool? = nil,
                supportsReasoning: Bool? = nil,
                supportsReasoningToggle: Bool? = nil,
                supportsPreserveReasoning: Bool? = nil,
                supportsReasoningEffort: Bool? = nil,
                reasoningEffortLevels: [String]? = nil) {
        self.source = source
        self.supportsToolCalls = supportsToolCalls
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsSystemRole = supportsSystemRole
        self.supportsReasoning = supportsReasoning
        self.supportsReasoningToggle = supportsReasoningToggle
        self.supportsPreserveReasoning = supportsPreserveReasoning
        self.supportsReasoningEffort = supportsReasoningEffort
        self.reasoningEffortLevels = reasoningEffortLevels
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case supportsToolCalls = "supports_tool_calls"
        case supportsParallelToolCalls = "supports_parallel_tool_calls"
        case supportsSystemRole = "supports_system_role"
        case supportsReasoning = "supports_reasoning"
        case supportsReasoningToggle = "supports_reasoning_toggle"
        case supportsPreserveReasoning = "supports_preserve_reasoning"
        case supportsReasoningEffort = "supports_reasoning_effort"
        case reasoningEffortLevels = "reasoning_effort_levels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source:                    try c.decodeIfPresent(String.self, forKey: .source),
            supportsToolCalls:         try c.decodeIfPresent(Bool.self, forKey: .supportsToolCalls),
            supportsParallelToolCalls: try c.decodeIfPresent(Bool.self, forKey: .supportsParallelToolCalls),
            supportsSystemRole:        try c.decodeIfPresent(Bool.self, forKey: .supportsSystemRole),
            supportsReasoning:         try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning),
            supportsReasoningToggle:   try c.decodeIfPresent(Bool.self, forKey: .supportsReasoningToggle),
            supportsPreserveReasoning: try c.decodeIfPresent(Bool.self, forKey: .supportsPreserveReasoning),
            supportsReasoningEffort:   try c.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort),
            reasoningEffortLevels:     try c.decodeIfPresent([String].self, forKey: .reasoningEffortLevels)
        )
    }
}

/// What the loaded model, projector and build can do, copied from the loaded
/// configuration. A capability here does not mean the engine API exposes it,
/// see ``EngineOperations``. `nil` means unknown.
public struct RuntimeModelCapabilities: Sendable, Hashable, Decodable {
    public var chat: Bool?
    public var inputImage: Bool?
    public var inputAudio: Bool?
    public var inputVideo: Bool?
    /// Output modalities, for example `["text"]` or `["text", "audio"]`.
    public var outputModalities: [String]?
    public var audioGeneration: Bool?
    public var audioSpeakerReference: Bool?
    /// Realtime transcription. On its own it does not mean a voice conversation.
    public var audioStream: Bool?
    public var realtimeConversation: Bool?
    public var multimodalProjector: Bool?

    enum CodingKeys: String, CodingKey {
        case chat
        case inputImage = "input_image"
        case inputAudio = "input_audio"
        case inputVideo = "input_video"
        case outputModalities = "output_modalities"
        case audioGeneration = "audio_generation"
        case audioSpeakerReference = "audio_speaker_reference"
        case audioStream = "audio_stream"
        case realtimeConversation = "realtime_conversation"
        case multimodalProjector = "multimodal_projector"
    }
}

/// What ``LlamaEngine`` can run with the loaded configuration. `false` also
/// covers features the model supports but the engine does not expose yet, such
/// as speech generation or realtime sessions. `nil` means unknown: treat it as
/// unavailable.
public struct EngineOperations: Sendable, Hashable, Decodable {
    public var chatCompletion: Bool?
    public var chatCompletionStream: Bool?
    public var countChatTokens: Bool?
    public var tokenize: Bool?
    /// Image content in chat completion requests.
    public var imageInput: Bool?
    /// Audio content in chat completion requests.
    public var audioInput: Bool?
    /// Video content in chat completion requests.
    public var videoInput: Bool?
    public var speechGeneration: Bool?
    public var transcription: Bool?
    public var realtime: Bool?

    enum CodingKeys: String, CodingKey {
        case chatCompletion = "chat_completion"
        case chatCompletionStream = "chat_completion_stream"
        case countChatTokens = "count_chat_tokens"
        case tokenize
        case imageInput = "image_input"
        case audioInput = "audio_input"
        case videoInput = "video_input"
        case speechGeneration = "speech_generation"
        case transcription
        case realtime
    }
}
