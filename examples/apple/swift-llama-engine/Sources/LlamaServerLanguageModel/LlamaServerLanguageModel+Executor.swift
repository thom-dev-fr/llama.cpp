import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public import FoundationModels
import LlamaOpenAICompatible

@available(iOS 27.0, macOS 27.0, *)
extension LlamaServerLanguageModel {
    /// The executor that sends Foundation Models requests to llama-server.
    ///
    /// `Executor` converts Foundation Models generation requests into
    /// OpenAI-compatible chat completion requests, sends them to the configured
    /// `/chat/completions` endpoint, and forwards streamed content back into
    /// Foundation Models.
    public struct Executor: LanguageModelExecutor {
        /// The model type handled by this executor.
        public typealias Model = LlamaServerLanguageModel

        private let configuration: Configuration

        /// Creates an executor for a llama-server language model.
        ///
        /// - Parameter configuration: The endpoint and request configuration
        ///   derived from ``LlamaServerLanguageModel/executorConfiguration``.
        public init(configuration: Configuration) {
            self.configuration = configuration
        }

        /// Configuration used by the llama-server language model executor.
        ///
        /// Foundation Models creates executors from this value when a
        /// `LanguageModelSession` starts using ``LlamaServerLanguageModel``.
        /// The configuration carries the endpoint settings and additional
        /// top-level request body fields needed for each generation.
        public struct Configuration: Hashable, Sendable {
            fileprivate let endpoint: LlamaOpenAICompatibleEndpointConfiguration
            fileprivate let extraBody: [String: LlamaOpenAICompatibleJSONValue]
            fileprivate let reasoningEffortMapping: ReasoningEffortMapping

            init(
                endpoint: LlamaOpenAICompatibleEndpointConfiguration,
                extraBody: [String: LlamaOpenAICompatibleJSONValue],
                reasoningEffortMapping: ReasoningEffortMapping = .openAICompatible
            ) {
                self.endpoint = endpoint
                self.extraBody = extraBody
                self.reasoningEffortMapping = reasoningEffortMapping
            }
        }

        /// Responds to a Foundation Models generation request.
        ///
        /// The executor converts `request` to llama.cpp's OpenAI-compatible
        /// chat completion format, sends the request to the configured
        /// llama-server endpoint, and streams text, reasoning, tool calls,
        /// usage, and telemetry into `channel`.
        ///
        /// - Parameters:
        ///   - request: The Foundation Models generation request to send.
        ///   - model: The model whose endpoint and test URL session should be
        ///     used for the request.
        ///   - channel: The streaming channel that receives generated output.
        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: LlamaServerLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let client = LlamaServerClient(
                streamingClient: configuration.endpoint.streamingClient(session: model.urlSession)
            )

            let generationRequest = try LlamaOpenAICompatibleGenerationRequestBuilder.request(
                from: request,
                modelName: configuration.endpoint.modelName,
                extraBody: configuration.reasoningEffortMapping.applying(
                    request.contextOptions.reasoningLevel,
                    to: configuration.extraBody
                ),
                unsupportedBy: Self.self
            ) {
                LlamaServerLanguageModel.RequestError.invalidRequest($0)
            }

            try await LlamaOpenAICompatibleGenerationStreamProcessor.process(
                client.streamGeneration(request: generationRequest),
                into: channel
            )
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct LlamaServerClient {
    typealias GenerationRequest = LlamaOpenAICompatibleChatCompletionRequest
    typealias GenerationChunk = LlamaOpenAICompatibleChatCompletionChunk<LlamaOpenAICompatibleTelemetryFields>

    let streamingClient: LlamaOpenAICompatibleStreamingClient

    func streamGeneration(
        request: GenerationRequest
    ) -> AsyncThrowingStream<GenerationChunk, any Error> {
        streamingClient.stream(
            endpoint: "/chat/completions",
            request: request,
            invalidStreamData: { LlamaServerLanguageModel.RequestError.invalidStreamData },
            httpError: { statusCode, data in
                LlamaServerLanguageModel.RequestError.httpError(statusCode: statusCode, data: data)
            },
            apiError: { error in
                LlamaServerLanguageModel.APIError(
                    message: error.message,
                    type: error.type,
                    param: error.param,
                    code: error.code
                )
            }
        )
    }
}
