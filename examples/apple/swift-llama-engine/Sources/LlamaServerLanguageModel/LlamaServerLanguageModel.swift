public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif
public import FoundationModels
public import LlamaOpenAICompatible

/// A `LanguageModel` that runs generations through a llama-server endpoint.
///
/// Use `LlamaServerLanguageModel` when inference is hosted by llama.cpp's
/// OpenAI-compatible HTTP server instead of running through a local
/// `LlamaEngine` instance. The adapter converts Foundation Models generation
/// requests to `/chat/completions` requests, streams server-sent events back
/// into Foundation Models, and exposes llama.cpp telemetry as response metadata.
///
/// Create a model with the server URL and any request-level options the server
/// should receive:
///
/// ```swift
/// let model = LlamaServerLanguageModel(
///     name: "Qwen3-4B-Instruct",
///     url: URL(string: "http://localhost:8080")!,
///     additionalHeaders: [
///         "Authorization": "Bearer token"
///     ],
///     extraBody: [
///         "timings_per_token": .bool(true),
///         "return_progress": .bool(true)
///     ],
///     reasoningEffortMapping: .init([.deep: .high, .custom("xhigh"): .xhigh]),
///     contextSize: 4096,
///     capabilities: [.toolCalling, .reasoning]
/// )
/// ```
///
/// The `url` value is the server base URL. The executor sends generation
/// requests to the server's `/chat/completions` route.
@available(iOS 27.0, macOS 27.0, *)
public struct LlamaServerLanguageModel: Sendable, LanguageModel {
    /// OpenAI-compatible reasoning-effort value type used by this adapter.
    public typealias ReasoningEffort = LlamaOpenAICompatibleReasoningEffort

    /// Mapping from Foundation Models reasoning levels to llama.cpp chat
    /// template keyword arguments.
    public typealias ReasoningEffortMapping = LlamaOpenAICompatibleReasoningEffortMapping

    /// The model identifier sent in the `model` request field.
    public var name: String

    /// The base URL of the llama-server endpoint.
    ///
    /// The executor appends `/chat/completions` when sending generation
    /// requests.
    public var url: URL

    /// Headers added to every outgoing request.
    ///
    /// Use this property for authentication headers or deployment-specific
    /// routing headers required by the server.
    public var additionalHeaders: [String: String]

    /// Extra top-level JSON fields added to every generation request.
    ///
    /// Use this dictionary for llama.cpp-specific request fields that are not
    /// represented by Foundation Models, such as `timings_per_token` or
    /// `return_progress`.
    public var extraBody: [String: LlamaOpenAICompatibleJSONValue]

    /// Mapping from Foundation Models reasoning levels to llama.cpp chat
    /// template keyword arguments.
    ///
    /// When a request includes `ContextOptions.reasoningLevel`, the executor
    /// writes the mapped value under `chat_template_kwargs` (`reasoning_effort`
    /// by default). It also writes `chat_template_kwargs.enable_thinking` as a
    /// boolean. This is most useful for models that declare the `.reasoning`
    /// capability.
    public var reasoningEffortMapping: ReasoningEffortMapping

    /// The model capabilities declared to Foundation Models.
    public var capabilities: LanguageModelCapabilities

    /// The context size, when known by the adapter configuration.
    ///
    /// The server adapter does not probe the remote model. Pass this value when
    /// the host application already knows the model's context window.
    public var contextSize: Int?

    // Overridden in tests to inject a URLSession with mock protocol handlers.
    var urlSession: URLSession?

    /// Creates a llama-server language model.
    ///
    /// - Parameters:
    ///   - name: The model identifier to include in generation requests.
    ///   - url: The base URL of the llama-server endpoint.
    ///   - additionalHeaders: Headers to add to every outgoing HTTP request.
    ///   - extraBody: Additional top-level JSON fields to merge into every
    ///     generation request.
    ///   - reasoningEffortMapping: Mapping used to translate
    ///     `ContextOptions.reasoningLevel` into llama.cpp `chat_template_kwargs`
    ///     when the request asks for reasoning.
    ///   - contextSize: The model context window, when known.
    ///   - capabilities: The individual capabilities to expose to Foundation
    ///     Models.
    public init(
        name: String,
        url: URL,
        additionalHeaders: [String: String] = [:],
        extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
        reasoningEffortMapping: ReasoningEffortMapping = .openAICompatible,
        contextSize: Int? = nil,
        capabilities: [LanguageModelCapabilities.Capability] = Self.defaultCapabilities
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.extraBody = extraBody
        self.reasoningEffortMapping = reasoningEffortMapping
        self.contextSize = contextSize
        self.capabilities = LanguageModelCapabilities(capabilities)
    }

    /// The executor configuration used by `LanguageModelSession`.
    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            endpoint: LlamaOpenAICompatibleEndpointConfiguration(
                modelName: name,
                baseURL: url,
                additionalHeaders: additionalHeaders
            ),
            extraBody: extraBody,
            reasoningEffortMapping: reasoningEffortMapping
        )
    }

    /// The standard Foundation Models reasoning levels that map to enabled
    /// llama.cpp thinking for this model.
    public var supportedReasoningLevels: [ContextOptions.ReasoningLevel] {
        reasoningEffortMapping.supportedReasoningLevels
    }

    /// Default capabilities for llama-server's OpenAI-compatible endpoint.
    ///
    /// Remote servers do not expose a standard capability probe through this
    /// adapter, so callers should pass an explicit capability list when the
    /// served model supports additional features such as reasoning or vision.
    public static let defaultCapabilities: [LanguageModelCapabilities.Capability] = [
        .toolCalling
    ]

    /// Shared llama.cpp telemetry metadata keys emitted by this model.
    public enum MetadataKeys {
        /// Per-token timing telemetry, when `timings_per_token` is enabled.
        public static let timings = LlamaTelemetryMetadataKeys.timings

        /// Prompt processing progress telemetry, when `return_progress` is
        /// enabled.
        public static let promptProgress = LlamaTelemetryMetadataKeys.promptProgress
    }

    /// An error returned by a llama-server OpenAI-compatible error envelope.
    public struct APIError: LocalizedError {
        /// The server-provided error message.
        public var message: String

        /// The server-provided error type, when present.
        public var type: String?

        /// The request parameter associated with the error, when present.
        public var param: String?

        /// The server-provided error code, when present.
        public var code: String?

        /// Creates an error from a llama-server error envelope.
        ///
        /// - Parameters:
        ///   - message: The server-provided error message.
        ///   - type: The server-provided error type, when present.
        ///   - param: The request parameter associated with the error, when
        ///     present.
        ///   - code: The server-provided error code, when present.
        public init(message: String, type: String? = nil, param: String? = nil, code: String? = nil) {
            self.message = message
            self.type = type
            self.param = param
            self.code = code
        }

        /// A localized description of the server error.
        public var errorDescription: String? {
            let details = [
                type.map { "type=\($0)" },
                param.map { "param=\($0)" },
                code.map { "code=\($0)" },
            ].compactMap { $0 }.joined(separator: ", ")
            return details.isEmpty ? message : "\(message) (\(details))"
        }
    }

    /// Request and stream errors raised by ``LlamaServerLanguageModel``.
    public enum RequestError: LocalizedError {
        /// The Foundation Models request could not be converted to llama.cpp's
        /// OpenAI-compatible request format.
        case invalidRequest(String)

        /// A streamed generation chunk could not be decoded.
        case invalidStreamData

        /// The HTTP endpoint returned a non-success status code.
        case httpError(statusCode: Int, data: Data)

        /// A localized description of the request or stream error.
        public var errorDescription: String? {
            switch self {
            case .invalidRequest(let description):
                "Invalid request: \(description)"
            case .invalidStreamData:
                "Invalid streaming data received"
            case .httpError(let statusCode, let data):
                """
                HTTP error with status code \(statusCode):
                \(String(data: data, encoding: .utf8) ?? data.description)
                """
            }
        }
    }
}
