import Foundation
import FoundationModels
import LlamaEngine

/// Errors of the adapter that Foundation Models has no case for. Runtime
/// errors (`queueFull`, `admissionTimedOut`, `unloaded`, `modelNotFound`,
/// `modelUnavailable`, native engine errors) stay `LlamaEngineError`.
public enum LlamaLanguageModelError: Error, Sendable, Equatable {
    /// A generation option has no faithful engine translation.
    case unsupportedOption(name: String, reason: String)
    /// The generation stopped inside a tool call: its arguments are incomplete.
    case incompleteToolCall(name: String, reason: String)
    /// The engine produced output this adapter cannot read.
    case invalidEngineOutput(String)
}

extension LlamaLanguageModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedOption(name, reason):
            return "Unsupported generation option \(name): \(reason)"
        case let .incompleteToolCall(name, reason):
            return "The call of tool '\(name)' is incomplete: \(reason)"
        case let .invalidEngineOutput(reason):
            return "Unreadable llama.cpp output: \(reason)"
        }
    }
}

extension LanguageModelError {
    /// The Foundation Models error for an engine context overflow. The phase
    /// and the engine diagnostic go in `debugDescription`: the iOS 27.0 runtime
    /// returns an empty `metadata` for this error.
    static func contextSizeExceeded(_ overflow: LlamaContextOverflow) -> LanguageModelError {
        .contextSizeExceeded(.init(
            contextSize: overflow.contextSize,
            tokenCount: overflow.requiredTokens,
            debugDescription: "context full during \(overflow.phase.rawValue): \(overflow.message)"))
    }

    static func unsupported(_ capability: LanguageModelCapabilities.Capability, _ reason: String) -> LanguageModelError {
        .unsupportedCapability(.init(capability: capability, debugDescription: reason))
    }
}

/// Maps an error of the engine boundary to the error `respond` throws: the
/// Foundation Models type when one matches, the typed runtime error otherwise.
/// The engine diagnostic is kept in `debugDescription`.
func translateEngineError(_ error: any Error, schemaName: String?) -> any Error {
    guard let engineError = error as? LlamaEngineError else {
        return error
    }
    switch engineError {
    case let .contextExceeded(overflow):
        return LanguageModelError.contextSizeExceeded(overflow)
    case let .native(category, message, _):
        if category == "cancelled" {
            return CancellationError()
        }
        guard category == "invalid_request" else {
            return engineError
        }
        // Refusals of the request contract that Foundation Models has a case for.
        if message.hasPrefix("response_format:") {
            return LanguageModelError.unsupportedGenerationGuide(.init(schemaName: schemaName, debugDescription: message))
        }
        if message.hasPrefix("parameters of tool ") {
            let tool = message.dropFirst("parameters of tool ".count).prefix { $0 != ":" }
            return LanguageModelError.unsupportedGenerationGuide(.init(schemaName: String(tool), debugDescription: message))
        }
        if message.contains("does not support tools combined with a response format") {
            return LanguageModelError.unsupported(.toolCalling, message)
        }
        if message.contains("image input is not supported") {
            return LanguageModelError.unsupported(.vision, message)
        }
        return engineError
    default:
        return engineError
    }
}
