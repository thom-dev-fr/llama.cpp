import Foundation
import LlamaEngineCore

/// Thread-safe Swift facade over the C engine.
///
/// Concurrency is owned by the C++ `Engine Core`: long-running entry points are
/// `async` and execute their blocking C work off the caller's executor.
public final class LlamaEngine: @unchecked Sendable {
    let handle: OpaquePointer

    public init() {
        guard let h = llama_engine_create() else {
            fatalError("llama_engine_create returned null")
        }
        self.handle = h
    }

    public var tokenCounting: TokenCountingService {
        TokenCountingService(engine: self)
    }

    deinit {
        llama_engine_destroy(handle)
    }

    public static func setLogLevel(_ level: LogLevel) {
        llama_engine_set_log_level(llama_engine_log_level(UInt32(level.rawValue)))
    }

    public var state: EngineState {
        let raw = llama_engine_get_state(handle)
        return EngineState(rawValue: Int(raw.rawValue)) ?? .unloaded
    }

    /// True when Multi-Token Prediction speculative decoding is currently
    /// wired up against the loaded model. False when the engine is unloaded.
    public var isMTPActive: Bool {
        llama_engine_is_mtp_active(handle)
    }

    /// Probe the GGUF metadata of a model file without loading the weights.
    public static func modelInfo(modelURL: URL,
                                 mmprojURL: URL? = nil) async throws -> ModelInfo {
        try await Task.detached(priority: .userInitiated) {
            try ModelInfoProbe.probe(modelURL: modelURL, mmprojURL: mmprojURL)
        }.value
    }

    // MARK: - Lifecycle

    public func load(_ config: ModelConfig) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.loadSync(config)
        }.value
    }

    public func unload() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.unloadSync()
        }.value
    }

    /// Transition to `.paused`. Safe to call concurrently with an in-flight
    /// `load()` or `resume()`.
    public func pause() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.pauseSync()
        }.value
    }

    /// Transition from `.paused` back to `.ready` by reloading the cached config.
    public func resume() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.resumeSync()
        }.value
    }

    // MARK: - Tokenization

    public func tokenize(_ text: String, addSpecial: Bool = true) async throws -> [Int32] {
        try await Task.detached(priority: .userInitiated) {
            try self.tokenizeSync(text, addSpecial: addSpecial)
        }.value
    }

    public func detokenize(_ tokens: [Int32]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.detokenizeSync(tokens)
        }.value
    }

    // MARK: - Chat completion

    /// `requestJSON` is an OpenAI-compatible chat-completion request.
    /// Returns the raw JSON response.
    public func chatCompletion(requestJSON: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.chatCompletionSync(requestJSON: requestJSON)
        }.value
    }

    /// Opens a single-consumer engine stream of OpenAI-compatible JSON chunks.
    /// Each yielded string is one OAI chunk without SSE framing or `[DONE]`.
    public func chatCompletionStream(requestJSON: String) async throws -> EngineStream {
        try await Task.detached(priority: .userInitiated) {
            try self.openChatCompletionStreamSync(requestJSON: requestJSON)
        }.value
    }
}
