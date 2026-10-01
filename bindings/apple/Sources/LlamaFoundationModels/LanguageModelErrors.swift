import Foundation
import FoundationModels
import LlamaEngine

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
}

