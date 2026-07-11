public import Foundation
public import FoundationModels
public import LlamaEngine
public import LlamaOpenAICompatible

/// A `LanguageModel` that runs generations with a local llama.cpp model.
///
/// Use `LlamaLanguageModel` when the model weights are available on device and
/// inference should run through `LlamaEngine` instead of a remote server. The
/// adapter converts Foundation Models generation requests to llama.cpp's
/// OpenAI-compatible chat completions format, streams the result back into the
/// Foundation Models executor channel, and exposes llama.cpp telemetry as
/// response metadata.
///
/// Create an instance with a known capability set:
///
/// ```swift
/// let model = LlamaLanguageModel(
///     name: "Qwen3-4B-Instruct",
///     configuration: ModelConfig(
///         modelPath: modelURL,
///         contextSize: 4096,
///         gpuLayers: -1,
///         flashAttention: true
///     ),
///     extraBody: [
///         "timings_per_token": .bool(true),
///         "return_progress": .bool(true)
///     ],
///     reasoningEffortMapping: .init([.moderate: .low, .deep: .xhigh]),
///     capabilities: [.toolCalling, .reasoning]
/// )
/// ```
///
/// If the capability set should be read from GGUF metadata, create the adapter
/// with ``probing(name:configuration:)``.
@available(iOS 27.0, macOS 27.0, *)
public struct LlamaLanguageModel: Sendable, LanguageModel {
    /// OpenAI-compatible reasoning-effort value type used by this adapter.
    public typealias ReasoningEffort = LlamaOpenAICompatibleReasoningEffort

    /// Mapping from Foundation Models reasoning levels to llama.cpp chat
    /// template keyword arguments.
    public typealias ReasoningEffortMapping = LlamaOpenAICompatibleReasoningEffortMapping

    /// The model identifier sent in the `model` request field.
    public let name: String

    /// The local llama.cpp model configuration used to load `LlamaEngine`.
    public let configuration: ModelConfig

    /// Extra top-level JSON fields added to every generation request.
    ///
    /// Use this dictionary for llama.cpp-specific request fields that are not
    /// represented by Foundation Models, such as `timings_per_token`,
    /// `return_progress`, or media path gates.
    public let extraBody: [String: LlamaOpenAICompatibleJSONValue]

    /// Mapping from Foundation Models reasoning levels to llama.cpp chat
    /// template keyword arguments.
    ///
    /// When a request includes `ContextOptions.reasoningLevel`, the executor
    /// writes the mapped value under `chat_template_kwargs` (`reasoning_effort`
    /// by default). It also writes `chat_template_kwargs.enable_thinking` as a
    /// boolean. This is most useful for models that declare the `.reasoning`
    /// capability.
    public let reasoningEffortMapping: ReasoningEffortMapping

    /// The model capabilities declared to Foundation Models.
    public let capabilities: LanguageModelCapabilities

    /// Shared local runtime state owned by this model value's reference storage.
    ///
    /// `LanguageModelExecutor` instances are created and cached by Foundation
    /// Models. They are not a stable owner for loaded local model resources, so
    /// copies of one `LlamaLanguageModel` value share this storage instead.
    let runtimeStorage: LlamaLanguageModelRuntimeStorage

    /// Creates a local llama language model with an explicit capability set.
    ///
    /// - Parameters:
    ///   - name: The model identifier to include in generation requests.
    ///   - configuration: The llama.cpp model configuration used when the
    ///     executor loads the model.
    ///   - extraBody: Additional top-level JSON fields to merge into every
    ///     generation request.
    ///   - reasoningEffortMapping: Mapping used to translate
    ///     `ContextOptions.reasoningLevel` into llama.cpp `chat_template_kwargs`
    ///     when the request asks for reasoning.
    ///   - capabilities: The capabilities to expose to Foundation Models.
    public init(
        name: String,
        configuration: ModelConfig,
        extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
        reasoningEffortMapping: ReasoningEffortMapping = .openAICompatible,
        capabilities: LanguageModelCapabilities
    ) {
        self.name = name
        self.configuration = configuration
        self.extraBody = extraBody
        self.reasoningEffortMapping = reasoningEffortMapping
        self.capabilities = capabilities
        self.runtimeStorage = LlamaLanguageModelRuntimeStorage(
            configuration: Executor.Configuration(
                name: name,
                configuration: configuration,
                extraBody: extraBody,
                reasoningEffortMapping: reasoningEffortMapping
            )
        )
    }

    /// Creates a local llama language model with an array of capability values.
    ///
    /// - Parameters:
    ///   - name: The model identifier to include in generation requests.
    ///   - configuration: The llama.cpp model configuration used when the
    ///     executor loads the model.
    ///   - extraBody: Additional top-level JSON fields to merge into every
    ///     generation request.
    ///   - reasoningEffortMapping: Mapping used to translate
    ///     `ContextOptions.reasoningLevel` into llama.cpp `chat_template_kwargs`
    ///     when the request asks for reasoning.
    ///   - capabilities: The individual capabilities to expose to Foundation
    ///     Models.
    public init(
        name: String,
        configuration: ModelConfig,
        extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
        reasoningEffortMapping: ReasoningEffortMapping = .openAICompatible,
        capabilities: [LanguageModelCapabilities.Capability]
    ) {
        self.init(
            name: name,
            configuration: configuration,
            extraBody: extraBody,
            reasoningEffortMapping: reasoningEffortMapping,
            capabilities: LanguageModelCapabilities(capabilities)
        )
    }

    /// Creates a local llama language model by reading capabilities from model
    /// metadata.
    ///
    /// This method asks `LlamaEngine` to inspect GGUF metadata for the model
    /// and optional multimodal projector in `configuration`. It does not load
    /// the full model weights for generation.
    ///
    /// ```swift
    /// let model = try await LlamaLanguageModel.probing(
    ///     name: "Qwen2-VL-7B-Instruct",
    ///     configuration: ModelConfig(
    ///         modelPath: modelURL,
    ///         mtmdProjectorPath: projectorURL
    ///     )
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - name: The model identifier to include in generation requests.
    ///   - configuration: The model configuration whose model and projector
    ///     metadata should be inspected.
    /// - Returns: A model whose capabilities match the metadata reported by
    ///   `LlamaEngine`.
    public static func probing(
        name: String,
        configuration: ModelConfig
    ) async throws -> LlamaLanguageModel {
        let info = try await LlamaEngine.modelInfo(
            modelURL: configuration.modelPath,
            mmprojURL: configuration.mtmdProjectorPath
        )
        return LlamaLanguageModel(
            name: name,
            configuration: configuration,
            capabilities: foundationModelCapabilities(from: info.capabilities)
        )
    }

    /// The standard Foundation Models reasoning levels that map to enabled
    /// llama.cpp thinking for this model.
    public var supportedReasoningLevels: [ContextOptions.ReasoningLevel] {
        reasoningEffortMapping.supportedReasoningLevels
    }

    /// Converts llama.cpp model capabilities into Foundation Models
    /// capabilities.
    ///
    /// The returned value always includes `.guidedGeneration`. Tool calling,
    /// reasoning, and vision are added when the llama.cpp metadata declares
    /// support for those features.
    ///
    /// - Parameter capabilities: The capabilities reported by `LlamaEngine`.
    /// - Returns: The equivalent Foundation Models capability set.
    public static func foundationModelCapabilities(
        from capabilities: ModelCapabilities
    ) -> LanguageModelCapabilities {
        var declared: [LanguageModelCapabilities.Capability] = [
            .guidedGeneration
        ]

        if capabilities.supportsToolCalls {
            declared.append(.toolCalling)
        }
        if capabilities.supportsReasoning {
            declared.append(.reasoning)
        }
        if capabilities.supportsVision {
            declared.append(.vision)
        }

        return LanguageModelCapabilities(declared)
    }

    /// The executor configuration used by `LanguageModelSession`.
    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            name: name,
            configuration: configuration,
            extraBody: extraBody,
            reasoningEffortMapping: reasoningEffortMapping
        )
    }

    /// The configured context window size, when known.
    ///
    /// A `ModelConfig.contextSize` value of `0` means the effective engine
    /// default is unknown, so this property returns `nil`.
    public var contextSize: Int? {
        configuration.contextSize > 0 ? Int(configuration.contextSize) : nil
    }

    /// A snapshot of whether the model can serve a request.
    ///
    /// The value is projected from the local engine lifecycle and on-disk file
    /// presence. It is additive convenience API for driving host UI, not a
    /// Foundation Models protocol requirement.
    ///
    /// `available` means the model file is present on disk but not yet loaded;
    /// a generation loads it on demand. `ready` means the model is loaded in
    /// memory and can serve a request immediately.
    public var availability: Availability {
        get async {
            await runtimeStorage.runtime.availability()
        }
    }

    /// The availability of a ``LlamaLanguageModel`` for inference.
    public enum Availability: Sendable, Equatable {
        /// The model file is present on disk but not loaded. A generation loads
        /// it on demand.
        case available

        /// The engine is loading the model into memory.
        case loading

        /// The engine is resuming a previously paused model.
        case resuming

        /// The model is loaded and can serve a request immediately.
        case ready

        /// The engine is pausing the loaded model.
        case pausing

        /// The model is paused, typically after the app entered the background.
        case paused

        /// The engine is unloading the model.
        case unloading

        /// The model cannot serve a request.
        case unavailable(UnavailableReason)

        /// The reason a ``LlamaLanguageModel`` cannot currently serve requests.
        public enum UnavailableReason: Sendable, Equatable {
            /// The model file, or the configured multimodal projector, is not
            /// present at its configured path.
            case modelFileMissing

            /// The most recent load attempt failed. Clears on a subsequent
            /// successful load.
            case loadFailed
        }
    }

    /// Shared llama.cpp telemetry metadata keys emitted by this model.
    public enum MetadataKeys {
        /// Per-token timing telemetry, when `timings_per_token` is enabled.
        public static let timings = LlamaTelemetryMetadataKeys.timings

        /// Prompt processing progress telemetry, when `return_progress` is
        /// enabled.
        public static let promptProgress = LlamaTelemetryMetadataKeys.promptProgress
    }
}

/// Errors raised by ``LlamaLanguageModel`` while preparing or processing a
/// generation.
@available(iOS 27.0, macOS 27.0, *)
public enum LlamaLanguageModelError: Error, LocalizedError, Sendable {
    /// A generation was requested while the same executor was already
    /// generating.
    case concurrentGeneration

    /// The Foundation Models request could not be converted to llama.cpp's
    /// OpenAI-compatible request format.
    case invalidRequest(String)

    /// A streamed generation chunk could not be decoded.
    case invalidStreamData(String)

    /// llama.cpp returned an OpenAI-compatible error envelope.
    case apiError(message: String, type: String?, param: String?, code: String?)

    /// A localized description of the model adapter error.
    public var errorDescription: String? {
        switch self {
        case .concurrentGeneration:
            return "LlamaLanguageModel does not support simultaneous generations for one executor."
        case .invalidRequest(let description):
            return "Invalid LlamaLanguageModel request: \(description)"
        case .invalidStreamData(let jsonString):
            return "Invalid OpenAI-compatible generation stream chunk: \(jsonString)"
        case .apiError(let message, let type, let param, let code):
            let details = [
                type.map { "type=\($0)" },
                param.map { "param=\($0)" },
                code.map { "code=\($0)" },
            ].compactMap { $0 }.joined(separator: ", ")
            return details.isEmpty ? message : "\(message) (\(details))"
        }
    }
}
