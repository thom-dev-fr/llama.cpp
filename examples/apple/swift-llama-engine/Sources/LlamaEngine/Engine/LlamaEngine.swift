import Foundation
import LlamaEngineCore

/// A thread-safe Swift facade over the llama.cpp engine.
///
/// `LlamaEngine` owns one native engine instance and exposes async Swift entry
/// points for model lifecycle, tokenization, and OpenAI-compatible chat
/// completion requests. Long-running operations execute their
/// blocking C work away from the caller's executor, while concurrency control
/// is handled by the C++ engine
/// core.
///
/// Create an engine, load a model, and stream an OpenAI-compatible chat
/// completion request:
///
/// ```swift
/// let engine = LlamaEngine()
/// LlamaEngine.setLogLevel(.info)
///
/// try await engine.load(ModelConfig(
///     modelPath: modelURL,
///     contextSize: 4096,
///     gpuLayers: -1,
///     flashAttention: true
/// ))
///
/// let request = #"""
/// {
///   "messages": [
///     { "role": "user", "content": "Say hello." }
///   ],
///   "stream": true
/// }
/// """#
///
/// let stream = try await engine.chatCompletionStream(requestJSON: request)
/// for try await chunk in stream {
///     print(chunk)
/// }
///
/// try await engine.unload()
/// ```
///
/// A `LlamaEngine` instance represents a single loaded model at a time. Create
/// separate engine instances only when the host application intentionally needs
/// separate native engine lifetimes.
public final class LlamaEngine: @unchecked Sendable {
    let handle: OpaquePointer

    /// Creates an unloaded engine instance.
    ///
    /// The engine allocates its native handle immediately. Load model weights
    /// later with ``load(_:)``.
    public init() {
        guard let h = llama_engine_create() else {
            fatalError("llama_engine_create returned null")
        }
        self.handle = h
    }

    /// A service for counting tokens with the currently loaded model.
    ///
    /// Use this service after ``load(_:)`` succeeds. The service calls the
    /// engine's in-process OpenAI-compatible token counting routes.
    public var tokenCounting: TokenCountingService {
        TokenCountingService(engine: self)
    }

    deinit {
        llama_engine_destroy(handle)
    }

    /// Sets the process-wide llama engine log level.
    ///
    /// - Parameter level: The minimum log level emitted by the native engine.
    public static func setLogLevel(_ level: LogLevel) {
        llama_engine_set_log_level(llama_engine_log_level(UInt32(level.rawValue)))
    }

    /// The current lifecycle state of the engine.
    public var state: EngineState {
        let raw = llama_engine_get_state(handle)
        return EngineState(rawValue: Int(raw.rawValue)) ?? .unloaded
    }

    /// A Boolean value that indicates whether Multi-Token Prediction speculative
    /// decoding is active for the loaded model.
    ///
    /// This value is `false` when the engine is unloaded or when the active
    /// model configuration did not wire an MTP draft head.
    public var isMTPActive: Bool {
        llama_engine_is_mtp_active(handle)
    }

    /// Reads GGUF metadata for a model file without loading model weights.
    ///
    /// Use this method to inspect architecture, quantization, context metadata,
    /// and feature capabilities before deciding whether to register or load a
    /// model.
    ///
    /// ```swift
    /// let info = try await LlamaEngine.modelInfo(
    ///     modelURL: modelURL,
    ///     mmprojURL: projectorURL
    /// )
    /// print(info.architecture)
    /// print(info.capabilities.supportsVision)
    /// ```
    ///
    /// - Parameters:
    ///   - modelURL: The URL of the GGUF model file to inspect.
    ///   - mmprojURL: The URL of the multimodal projector file to inspect, when
    ///     the model ships with one.
    /// - Returns: Metadata and capability information read from the model files.
    public static func modelInfo(modelURL: URL,
                                 mmprojURL: URL? = nil) async throws -> ModelInfo {
        try await Task.detached(priority: .userInitiated) {
            try ModelInfoProbe.probe(modelURL: modelURL, mmprojURL: mmprojURL)
        }.value
    }

    // MARK: - Lifecycle

    /// Loads a model into the engine.
    ///
    /// Loading prepares the model weights, optional multimodal projector,
    /// runtime settings, and Metal resources described by `config`. Call this
    /// before tokenization or chat completion requests.
    ///
    /// - Parameter config: The model configuration to load.
    public func load(_ config: ModelConfig) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.loadSync(config)
        }.value
    }

    /// Unloads the current model and releases its runtime resources.
    ///
    /// After unloading, the engine returns to ``EngineState/unloaded`` and must
    /// be loaded again before handling tokenization or chat completion requests.
    public func unload() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.unloadSync()
        }.value
    }

    /// Pauses the loaded model runtime.
    ///
    /// Pause is useful when the application is entering the background or wants
    /// to temporarily release runtime resources while preserving the cached load
    /// configuration. It is safe to call concurrently with an in-flight
    /// ``load(_:)`` or ``resume()``.
    public func pause() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.pauseSync()
        }.value
    }

    /// Resumes a paused model runtime.
    ///
    /// Resume transitions the engine from ``EngineState/paused`` back to
    /// ``EngineState/ready`` by reloading the cached model configuration.
    public func resume() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.resumeSync()
        }.value
    }

    // MARK: - Tokenization

    /// Converts text into model token IDs.
    ///
    /// The engine must have a model loaded before tokenization can succeed.
    ///
    /// - Parameters:
    ///   - text: The text to tokenize.
    ///   - addSpecial: A Boolean value that indicates whether the tokenizer
    ///     should add model-specific special tokens.
    /// - Returns: Token IDs produced by the loaded model tokenizer.
    public func tokenize(_ text: String, addSpecial: Bool = true) async throws -> [Int32] {
        try await Task.detached(priority: .userInitiated) {
            try self.tokenizeSync(text, addSpecial: addSpecial)
        }.value
    }

    /// Converts model token IDs back into text.
    ///
    /// The engine must have a model loaded before detokenization can succeed.
    ///
    /// - Parameter tokens: The token IDs to decode.
    /// - Returns: The decoded text.
    public func detokenize(_ tokens: [Int32]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.detokenizeSync(tokens)
        }.value
    }

    // MARK: - Chat completion

    /// Runs a non-streaming OpenAI-compatible chat completion request.
    ///
    /// `requestJSON` must contain an OpenAI-compatible `/chat/completions`
    /// request body. The returned string is the raw JSON response body produced
    /// by the engine.
    ///
    /// - Parameter requestJSON: The OpenAI-compatible chat completion request
    ///   JSON.
    /// - Returns: The raw OpenAI-compatible chat completion response JSON.
    public func chatCompletion(requestJSON: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.chatCompletionSync(requestJSON: requestJSON)
        }.value
    }

    /// Opens a stream for an OpenAI-compatible chat completion request.
    ///
    /// `requestJSON` must contain an OpenAI-compatible `/chat/completions`
    /// request body. The returned stream yields raw JSON chunks without SSE
    /// framing and without a final `[DONE]` marker.
    ///
    /// ```swift
    /// let stream = try await engine.chatCompletionStream(requestJSON: request)
    /// for try await chunk in stream {
    ///     print(chunk)
    /// }
    /// ```
    ///
    /// - Parameter requestJSON: The OpenAI-compatible chat completion request
    ///   JSON.
    /// - Returns: A single-consumer stream of OpenAI-compatible chunk JSON.
    public func chatCompletionStream(requestJSON: String) async throws -> EngineStream {
        try await Task.detached(priority: .userInitiated) {
            try self.openChatCompletionStreamSync(requestJSON: requestJSON)
        }.value
    }
}
