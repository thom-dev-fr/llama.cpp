import Foundation

/// Runtime shared by the sessions of an application (ADR 0002).
///
/// Created explicitly by the application; there is no hidden singleton. It will
/// own the native engine, the model catalog and the admission queue (P2/P3).
/// In this skeleton it only carries its identity and limits.
public final class LlamaRuntime: Sendable {
    public struct Limits: Hashable, Sendable {
        /// Models resident at the same time (loading and unloading included).
        public var maximumResidentModels: Int
        /// Generations running at the same time.
        public var maximumActiveGenerations: Int
        /// Requests waiting for admission; beyond that, submission fails.
        public var maximumWaitingRequests: Int

        public init(maximumResidentModels: Int = 1, maximumActiveGenerations: Int = 1, maximumWaitingRequests: Int = 4) {
            self.maximumResidentModels = maximumResidentModels
            self.maximumActiveGenerations = maximumActiveGenerations
            self.maximumWaitingRequests = maximumWaitingRequests
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }
}

/// Identity of a model artifact in the runtime catalog (weights and optional
/// projector). Two sessions using the same artifact and load profile share the
/// loaded weights.
public struct LlamaModelID: Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Settings that change the loaded resources. Two different profiles never share
/// the same loaded instance.
public struct LlamaLoadProfile: Hashable, Sendable {
    /// Context window of each generation, in tokens.
    public var contextSize: Int
    /// Layers offloaded to the GPU; nil keeps the engine default.
    public var gpuLayers: Int?

    public init(contextSize: Int = 4096, gpuLayers: Int? = nil) {
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
    }
}

/// Errors of the runtime, independent of Foundation Models.
public enum LlamaEngineError: Error, Sendable, Equatable {
    /// The native engine is not part of this build yet.
    case engineUnavailable(String)
    /// The prompt, or the prompt and the generated tokens, exceed the context.
    case contextExceeded(LlamaContextOverflow)
}

extension LlamaEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason):
            return "The llama.cpp engine is unavailable: \(reason)"
        case .contextExceeded(let overflow):
            return overflow.message
        }
    }
}
