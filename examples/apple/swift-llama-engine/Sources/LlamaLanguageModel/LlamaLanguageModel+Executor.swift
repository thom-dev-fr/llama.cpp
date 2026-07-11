import Foundation
public import FoundationModels
public import LlamaEngine
import LlamaOpenAICompatible

@available(iOS 27.0, macOS 27.0, *)
extension LlamaLanguageModel {
    /// The executor that loads a local llama.cpp model and streams generations
    /// into Foundation Models.
    ///
    /// `Executor` is the Foundation Models adapter for a local llama runtime.
    /// The loaded runtime is owned by `LlamaLanguageModel` so it can survive
    /// executor recreation across conversations and tool-set changes.
    public struct Executor: LanguageModelExecutor {
        /// The model type handled by this executor.
        public typealias Model = LlamaLanguageModel

        private let configuration: Configuration

        /// Creates an executor for a local llama language model.
        ///
        /// - Parameter configuration: The local runtime configuration derived
        ///   from ``LlamaLanguageModel/executorConfiguration``.
        public init(configuration: Configuration) {
            self.configuration = configuration
        }

        /// Configuration used by the local llama language model executor.
        ///
        /// Foundation Models creates executors from this value when a
        /// `LanguageModelSession` starts using ``LlamaLanguageModel``. The
        /// configuration carries the model identity, load configuration, and
        /// extra request body fields needed by the runtime.
        public struct Configuration: Hashable, Sendable {
            let name: String
            let configuration: ModelConfig
            let extraBody: [String: LlamaOpenAICompatibleJSONValue]
            let reasoningEffortMapping: ReasoningEffortMapping

            init(
                name: String,
                configuration: ModelConfig,
                extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
                reasoningEffortMapping: ReasoningEffortMapping = .openAICompatible
            ) {
                self.name = name
                self.configuration = configuration
                self.extraBody = extraBody
                self.reasoningEffortMapping = reasoningEffortMapping
            }
        }

        /// Responds to a Foundation Models generation request.
        ///
        /// The executor converts the request to llama.cpp's OpenAI-compatible
        /// chat completion JSON, runs `LlamaEngine.chatCompletionStream`, and
        /// forwards streamed text, reasoning, tool calls, usage, and telemetry
        /// into `channel`.
        ///
        /// - Parameters:
        ///   - request: The Foundation Models generation request to run.
        ///   - model: The model whose name and declared capabilities apply to
        ///     the request.
        ///   - channel: The streaming channel that receives generated output.
        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: LlamaLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let runtime = model.runtimeStorage.runtime
            let engine: LlamaEngine
            do {
                engine = try await runtime.beginGeneration()
            } catch {
                throw Self.mappedError(error)
            }

            do {
                let requestJSON = try LlamaOpenAICompatibleGenerationRequestBuilder.requestJSON(
                    from: request,
                    modelName: model.name,
                    extraBody: configuration.reasoningEffortMapping.applying(
                        request.contextOptions.reasoningLevel,
                        to: configuration.extraBody
                    ),
                    unsupportedBy: LlamaLanguageModel.self
                ) { description in
                    LlamaLanguageModelError.invalidRequest(description)
                }

                let stream = try await engine.chatCompletionStream(requestJSON: requestJSON)
                try await LlamaOpenAICompatibleGenerationStreamProcessor.processJSONStrings(
                    stream,
                    into: channel,
                    invalidStreamData: { jsonString in
                        LlamaLanguageModelError.invalidStreamData(jsonString)
                    },
                    apiError: { error in
                        LlamaLanguageModelError.apiError(
                            message: error.message,
                            type: error.type,
                            param: error.param,
                            code: error.code
                        )
                    }
                )

                await runtime.endGeneration()
            } catch {
                await runtime.endGeneration()
                throw Self.mappedError(error)
            }
        }

        /// Starts loading the local model before the first generation.
        ///
        /// Prewarming returns immediately and performs the load in a task owned
        /// by the executor runtime. A later call to ``respond(to:model:streamingInto:)``
        /// waits for the same load task instead of starting another load.
        ///
        /// - Parameters:
        ///   - model: The model being prepared. The runtime configuration was
        ///     already captured when the executor was created.
        ///   - transcript: The current transcript. The local llama adapter does
        ///     not need transcript contents to prewarm the model.
        public func prewarm(model: LlamaLanguageModel, transcript: Transcript) {
            let runtime = model.runtimeStorage.runtime
            Task {
                await runtime.prewarm()
            }
        }

        private static func mappedError(_ error: any Error) -> any Error {
            if error is CancellationError {
                return error
            }

            guard let llamaError = error as? LlamaError else {
                return error
            }

            switch llamaError {
            case .cancelled:
                return CancellationError()
            case .timeout:
                return LanguageModelError.timeout(
                    LanguageModelError.Timeout(
                        debugDescription: llamaError.description
                    )
                )
            case .invalidRequest(let message), .invalidArgument(let message):
                return LlamaLanguageModelError.invalidRequest(message)
            default:
                return error
            }
        }
    }
}
