import Foundation
import LlamaEngine

/// Settings kept across launches (conversations are not).
struct DemoSettings: Codable, Equatable, Sendable {
    /// The model of new conversations.
    var selectedModel: LlamaModelID?
    /// Context window of each generation, in tokens.
    var contextSize = 4096
    /// Runs the model on the GPU (Metal). The iOS simulator defaults to the
    /// CPU: its Metal device fails with Qwen3.5 (see the README).
    var usesGPU = DemoSettings.defaultUsesGPU
    /// Loads the projector of a model that has one (image input).
    var loadsProjector = true
    /// Lets a model that reasons do so (the template's default); off asks for none.
    var reasoning = false
    /// Offers the two local tools to a model that calls tools.
    var tools = true
    /// Greedy sampling instead of the model's defaults.
    var greedy = false
    var maximumResponseTokens = 1024

    static let contextSizes = [2048, 4096, 8192, 16384]
    static let responseTokenLimits = [256, 512, 1024, 2048, 4096]

    static var defaultUsesGPU: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private static let key = "demo.settings.v1"

    /// The saved settings; defaults when there are none or they are unreadable.
    static func load(from defaults: UserDefaults) -> DemoSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(DemoSettings.self, from: data) else {
            return DemoSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// The load profile of a conversation with `artifact`. Conversations keep
    /// the profile they started with; a changed setting applies to the next one.
    func profile(for artifact: LlamaModelArtifact) -> LlamaLoadProfile {
        LlamaLoadProfile(contextSize: contextSize,
                         compute: LlamaComputeConfiguration(offload: usesGPU ? .all : .none),
                         usesProjector: loadsProjector && artifact.projector != nil)
    }
}
