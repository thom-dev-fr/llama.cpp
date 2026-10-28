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
    case max
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

    /// Whether disabled reasoning writes `enable_thinking: false`. Turn it off
    /// for templates without a detected thinking toggle.
    public var disablesThinkingWhenOff: Bool = true

    /// Whether disabled reasoning writes the ``disabled`` value under
    /// ``chatTemplateKwarg``.
    public var writesDisabledEffort: Bool = true

    /// Whether a requested level without a mapping is an error, reported by
    /// ``unsupportedLevelDescription(for:)``, instead of disabled reasoning.
    public var rejectsUnmappedLevels: Bool = false

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

    /// A mapping built from the effort levels detected for a chat template,
    /// for example ``ChatTemplateCapabilities/reasoningEffortLevels``.
    ///
    /// Standard levels map only to their exact detected value: `.light ->
    /// low`, `.moderate -> medium`, `.deep -> high`. Every other detected
    /// value is offered as `.custom(value)`. Values this package does not know
    /// are skipped. A level that is not offered is rejected, see
    /// ``unsupportedLevelDescription(for:)``. Disabled reasoning only writes
    /// `enable_thinking: false` when the template has a known toggle.
    ///
    /// When the levels are unknown (`nil`), or when no usable level was
    /// detected, this returns ``openAICompatible``: an empty list does not
    /// mean the model cannot reason.
    ///
    /// - Parameters:
    ///   - reasoningEffortLevels: The detected effort values.
    ///   - supportsReasoningToggle: Whether the template has a thinking
    ///     toggle, `nil` when unknown.
    public static func automatic(
        reasoningEffortLevels: [String]?,
        supportsReasoningToggle: Bool?
    ) -> LlamaOpenAICompatibleReasoningEffortMapping {
        guard let detected = reasoningEffortLevels else { return .openAICompatible }

        let standard: [(LlamaOpenAICompatibleReasoningLevel, LlamaOpenAICompatibleReasoningEffort)] = [
            (.light, .low),
            (.moderate, .medium),
            (.deep, .high),
        ]
        var levels: [LlamaOpenAICompatibleReasoningLevel: LlamaOpenAICompatibleReasoningEffort] = [:]
        for (level, effort) in standard where detected.contains(effort.rawValue) {
            levels[level] = effort
        }
        for value in detected {
            guard let effort = LlamaOpenAICompatibleReasoningEffort(rawValue: value), effort != .none,
                  !standard.contains(where: { $0.1 == effort }) else { continue }
            levels[.custom(value)] = effort
        }
        guard !levels.isEmpty else { return .openAICompatible }

        var mapping = LlamaOpenAICompatibleReasoningEffortMapping(levels)
        mapping.disablesThinkingWhenOff = supportsReasoningToggle == true
        mapping.writesDisabledEffort = false
        mapping.rejectsUnmappedLevels = true
        return mapping
    }

    /// Describes why `level` cannot be sent with this mapping, or returns
    /// `nil` when it can. Only ``rejectsUnmappedLevels`` mappings reject a
    /// level.
    public func unsupportedLevelDescription(for level: ContextOptions.ReasoningLevel?) -> String? {
        guard rejectsUnmappedLevels, let level else { return nil }
        let key = LlamaOpenAICompatibleReasoningLevel(level)
        guard levels[key] == nil else { return nil }
        let supported = levels.keys.sorted().map { "\($0)" }.joined(separator: ", ")
        return "reasoning level \(key) is not supported by the chat template (supported: \(supported))"
    }

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
    /// mapped value is `none`, it disables template thinking, as allowed by
    /// ``disablesThinkingWhenOff`` and ``writesDisabledEffort``.
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

        if reasoningEnabled || writesDisabledEffort {
            chatTemplateKwargs[chatTemplateKwarg] = .string(effort)
        }
        if reasoningEnabled || disablesThinkingWhenOff {
            chatTemplateKwargs[enableThinkingKwarg] = .bool(reasoningEnabled)
        }
        if !chatTemplateKwargs.isEmpty {
            extraBody["chat_template_kwargs"] = .object(chatTemplateKwargs)
        }
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
