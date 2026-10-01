import Foundation
public import FoundationModels
public import LlamaEngine

/// Foundation Models `LanguageModel` backed by a llama.cpp model of a shared
/// `LlamaRuntime`.
///
/// The model value is lightweight: it names a catalog model and a load profile.
/// Its executor uses the runtime given here; the weights are loaded on demand.
///
/// P0 skeleton: no capability is declared and every request is refused with an
/// explicit error until the engine bridge exists (P2) and the translation is
/// implemented and qualified (P5).
public struct LlamaLanguageModel: LanguageModel {
    public typealias Executor = LlamaLanguageModelExecutor

    public let runtime: LlamaRuntime
    public let modelID: LlamaModelID
    public let profile: LlamaLoadProfile

    public init(runtime: LlamaRuntime, modelID: LlamaModelID, profile: LlamaLoadProfile = LlamaLoadProfile()) {
        self.runtime = runtime
        self.modelID = modelID
        self.profile = profile
    }

    /// Capabilities proven for this model. Only qualified metadata may add one;
    /// the skeleton declares none.
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(declaredCapabilities)
    }

    var declaredCapabilities: [LanguageModelCapabilities.Capability] { [] }

    public var executorConfiguration: LlamaLanguageModelExecutor.Configuration {
        LlamaLanguageModelExecutor.Configuration(runtime: runtime, modelID: modelID, profile: profile)
    }
}
