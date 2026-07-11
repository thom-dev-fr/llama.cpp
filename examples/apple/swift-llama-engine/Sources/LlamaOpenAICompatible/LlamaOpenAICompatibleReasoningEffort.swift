public import FoundationModels

/// OpenAI-compatible reasoning-effort values accepted by llama.cpp-compatible
/// generation endpoints.
@available(iOS 27.0, macOS 27.0, *)
public enum LlamaOpenAICompatibleReasoningEffort: String, Hashable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

/// A hashable reasoning-level key for llama.cpp reasoning-effort mappings.
@available(iOS 27.0, macOS 27.0, *)
public enum LlamaOpenAICompatibleReasoningLevel: Hashable, Sendable {
    case light
    case moderate
    case deep
    case custom(String)

    init(_ level: ContextOptions.ReasoningLevel) {
        switch level {
        case .light:
            self = .light
        case .moderate:
            self = .moderate
        case .deep:
            self = .deep
        case .custom(let value):
            self = .custom(value)
        @unknown default:
            self = .moderate
        }
    }

    var contextOptionsReasoningLevel: ContextOptions.ReasoningLevel {
        switch self {
        case .light:
            .light
        case .moderate:
            .moderate
        case .deep:
            .deep
        case .custom(let value):
            .custom(value)
        }
    }
}

/// A `Hashable` mapping from Foundation Models reasoning levels to llama.cpp
/// reasoning request fields.
@available(iOS 27.0, macOS 27.0, *)
public struct LlamaOpenAICompatibleReasoningEffortMapping: Hashable, Sendable {
    /// The `chat_template_kwargs` entry that receives the mapped effort value.
    public var chatTemplateKwarg: String

    /// The `chat_template_kwargs` entry that receives the thinking toggle.
    public var enableThinkingKwarg: String

    /// Value emitted when no Foundation Models reasoning level is requested or
    /// the requested level is not configured.
    public var disabled: LlamaOpenAICompatibleReasoningEffort

    /// Values emitted for configured Foundation Models reasoning levels.
    public var levels: [LlamaOpenAICompatibleReasoningLevel: LlamaOpenAICompatibleReasoningEffort]

    public init(
        _ levels: [LlamaOpenAICompatibleReasoningLevel: LlamaOpenAICompatibleReasoningEffort],
        chatTemplateKwarg: String = "reasoning_effort",
        enableThinkingKwarg: String = "enable_thinking",
        disabled: LlamaOpenAICompatibleReasoningEffort = .none
    ) {
        self.chatTemplateKwarg = chatTemplateKwarg
        self.enableThinkingKwarg = enableThinkingKwarg
        self.disabled = disabled
        self.levels = levels
    }

    /// The conventional llama.cpp/OpenAI-compatible mapping:
    /// `chat_template_kwargs.reasoning_effort` receives
    /// `.light -> low`, `.moderate -> medium`, `.deep -> high`; disabled
    /// reasoning uses `chat_template_kwargs.enable_thinking: false`.
    public static let openAICompatible = LlamaOpenAICompatibleReasoningEffortMapping([
        .light: .low,
        .moderate: .medium,
        .deep: .high,
    ])

    /// The Foundation Models reasoning levels that map to enabled llama.cpp
    /// thinking.
    public var supportedReasoningLevels: [ContextOptions.ReasoningLevel] {
        levels
            .filter { $0.value != .none }
            .keys
            .sorted()
            .map(\.contextOptionsReasoningLevel)
    }

    /// Returns the provider value for a Foundation Models reasoning level.
    public func value(for level: ContextOptions.ReasoningLevel) -> String {
        let key = LlamaOpenAICompatibleReasoningLevel(level)
        return (levels[key] ?? disabled).rawValue
    }

    /// Returns `extraBody` with llama.cpp reasoning controls applied.
    ///
    /// When a reasoning level is present and does not map to `none`, this sets
    /// `chat_template_kwargs.enable_thinking: true` and the mapped
    /// `chat_template_kwargs.reasoning_effort` value. When no reasoning level
    /// is present, when the requested level is not configured, or when the
    /// mapped value is `none`, it disables template thinking.
    public func applying(
        _ reasoningLevel: ContextOptions.ReasoningLevel?,
        to extraBody: [String: LlamaOpenAICompatibleJSONValue]
    ) -> [String: LlamaOpenAICompatibleJSONValue] {
        let effort = reasoningLevel.map(value(for:)) ?? disabled.rawValue
        let reasoningEnabled = effort.lowercased() != LlamaOpenAICompatibleReasoningEffort.none.rawValue

        var extraBody = extraBody
        var chatTemplateKwargs: [String: LlamaOpenAICompatibleJSONValue]
        if case .object(let existingKwargs) = extraBody["chat_template_kwargs"] {
            chatTemplateKwargs = existingKwargs
        } else {
            chatTemplateKwargs = [:]
        }

        chatTemplateKwargs[chatTemplateKwarg] = .string(effort)
        chatTemplateKwargs[enableThinkingKwarg] = .bool(reasoningEnabled)
        extraBody["chat_template_kwargs"] = .object(chatTemplateKwargs)
        return extraBody
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LlamaOpenAICompatibleReasoningLevel: Comparable {
    public static func < (
        lhs: LlamaOpenAICompatibleReasoningLevel,
        rhs: LlamaOpenAICompatibleReasoningLevel
    ) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        switch self {
        case .light:
            "0-light"
        case .moderate:
            "1-moderate"
        case .deep:
            "2-deep"
        case .custom(let value):
            "3-\(value)"
        }
    }
}
