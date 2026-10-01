import Foundation
public import FoundationModels
public import LlamaEngine

/// Foundation Models `LanguageModel` backed by a llama.cpp model of a shared
/// `LlamaRuntime`.
///
/// The model value is lightweight: it names a catalog model and a load
/// profile. Its executor uses the runtime given here; the weights are loaded
/// on demand (`prewarm` is optional).
///
/// Capabilities: guided generation is the engine's (a grammar constrains the
/// output whatever the model) and is always declared. Tool calling, reasoning
/// and vision come from the qualified capabilities of the catalog entry the
/// model was installed from; an imported or registered file gets none from its
/// name. An application that verified a model itself may pass `capabilities`.
/// Vision also needs a profile that loads the projector.
public struct LlamaLanguageModel: LanguageModel {
    public typealias Executor = LlamaLanguageModelExecutor

    public let runtime: LlamaRuntime
    public let modelID: LlamaModelID
    public let profile: LlamaLoadProfile
    /// Receives the progress and context occupancy of the requests.
    public let monitor: LlamaGenerationMonitor?
    private let declared: Set<LlamaModelCatalog.Capability>

    /// Overrides the engine boundary (adapter tests).
    let backendOverride: (any LlamaChatBackend)?

    /// - Parameter capabilities: nil derives them from the catalog entry of
    ///   the installed model (see the type documentation); a value replaces
    ///   them, under the application's responsibility.
    public init(runtime: LlamaRuntime, modelID: LlamaModelID, profile: LlamaLoadProfile = LlamaLoadProfile(),
                capabilities: Set<LlamaModelCatalog.Capability>? = nil, monitor: LlamaGenerationMonitor? = nil) {
        self.init(runtime: runtime, modelID: modelID, profile: profile, capabilities: capabilities, monitor: monitor,
                  backend: nil)
    }

    init(runtime: LlamaRuntime, modelID: LlamaModelID, profile: LlamaLoadProfile,
         capabilities: Set<LlamaModelCatalog.Capability>?, monitor: LlamaGenerationMonitor?,
         backend: (any LlamaChatBackend)?) {
        self.runtime = runtime
        self.modelID = modelID
        self.profile = profile
        self.monitor = monitor
        self.backendOverride = backend
        let artifact = (backend ?? runtime).artifact(modelID)
        if let capabilities {
            declared = capabilities
        } else {
            declared = Set(artifact?.catalogEntry?.qualifiedCapabilities ?? []).union([.guidedGeneration])
        }
    }

    var backend: any LlamaChatBackend { backendOverride ?? runtime }

    var capabilitySet: Set<LanguageModelCapabilities.Capability> {
        var result = Set<LanguageModelCapabilities.Capability>()
        for capability in declared {
            switch capability {
            case .guidedGeneration: result.insert(.guidedGeneration)
            case .toolCalling: result.insert(.toolCalling)
            case .reasoning: result.insert(.reasoning)
            case .vision where profile.usesProjector: result.insert(.vision)
            case .vision: break
            }
        }
        return result
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(Array(capabilitySet))
    }

    public var executorConfiguration: LlamaLanguageModelExecutor.Configuration {
        LlamaLanguageModelExecutor.Configuration(runtime: runtime, modelID: modelID, profile: profile)
    }
}
