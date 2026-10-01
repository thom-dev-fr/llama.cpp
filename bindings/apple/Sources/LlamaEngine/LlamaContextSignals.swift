import Foundation

/// Context use of one request, as reported by the engine when the request sets
/// `return_context` (see docs/design/embedded-inference-engine-api.md).
public struct LlamaContextReport: Codable, Hashable, Sendable {
    /// Effective capacity of the context serving the request.
    public var contextSize: Int
    /// Tokens occupying it: prompt (images and tool definitions included) and
    /// generated tokens, or the prompt tokens processed so far.
    public var occupiedTokens: Int
    public var promptTokens: Int
    /// Prompt prefix reused from the cache.
    public var cachedTokens: Int
    public var generatedTokens: Int
    /// Generated tokens inside the template's reasoning tags.
    public var reasoningTokens: Int

    enum CodingKeys: String, CodingKey {
        case contextSize = "n_ctx"
        case occupiedTokens = "n_tokens"
        case promptTokens = "n_prompt_tokens"
        case cachedTokens = "n_cache_tokens"
        case generatedTokens = "n_decoded"
        case reasoningTokens = "n_reasoning_tokens"
    }

    public init(contextSize: Int, occupiedTokens: Int, promptTokens: Int, cachedTokens: Int,
                generatedTokens: Int, reasoningTokens: Int) {
        self.contextSize = contextSize
        self.occupiedTokens = occupiedTokens
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.generatedTokens = generatedTokens
        self.reasoningTokens = reasoningTokens
    }

    /// Occupied share of the context, in 0...1.
    public var occupancy: Double {
        contextSize > 0 ? min(1, Double(occupiedTokens) / Double(contextSize)) : 0
    }
}

/// The context could not hold the request.
public struct LlamaContextOverflow: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        /// The prompt alone does not fit; nothing was generated.
        case prompt
        /// The context filled during generation, before the output budget.
        case generation
    }

    public var phase: Phase
    public var contextSize: Int
    public var promptTokens: Int
    public var generatedTokens: Int
    public var message: String

    public init(phase: Phase, contextSize: Int, promptTokens: Int, generatedTokens: Int, message: String) {
        self.phase = phase
        self.contextSize = contextSize
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.message = message
    }

    /// Tokens the request needed when it stopped.
    public var requiredTokens: Int {
        phase == .prompt ? promptTokens : promptTokens + generatedTokens + 1
    }

    /// Reads the native data of a `context_exceeded` engine error. Requests of
    /// this library set `fail_on_context_full`, so the phase is always present.
    public init?(errorData: Data) {
        struct Native: Decodable {
            var type: String?
            var message: String?
            var n_ctx: Int
            var n_prompt_tokens: Int
            var context_phase: String
            var n_decoded: Int?
        }
        guard let native = try? JSONDecoder().decode(Native.self, from: errorData),
              native.type == "exceed_context_size_error",
              let phase = Phase(rawValue: native.context_phase) else {
            return nil
        }
        self.init(phase: phase, contextSize: native.n_ctx, promptTokens: native.n_prompt_tokens,
                  generatedTokens: native.n_decoded ?? 0, message: native.message ?? "")
    }
}
