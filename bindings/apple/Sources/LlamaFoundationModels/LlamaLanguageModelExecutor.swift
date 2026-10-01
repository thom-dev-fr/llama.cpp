import Foundation
public import FoundationModels
public import LlamaEngine

/// Executor of `LlamaLanguageModel`. Foundation Models creates it from the
/// model's configuration and keeps the transcript and the tool loop; the
/// executor translates one request at a time for the shared runtime.
public struct LlamaLanguageModelExecutor: LanguageModelExecutor {
    public typealias Model = LlamaLanguageModel

    /// Identity of an executor: the runtime instance (by identity, not by value),
    /// the catalog model and the load profile. Executors of different runtimes
    /// never compare equal, so they never share resources by accident.
    public struct Configuration: Hashable, Sendable {
        public let runtime: LlamaRuntime
        public let modelID: LlamaModelID
        public let profile: LlamaLoadProfile

        public init(runtime: LlamaRuntime, modelID: LlamaModelID, profile: LlamaLoadProfile) {
            self.runtime = runtime
            self.modelID = modelID
            self.profile = profile
        }

        public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.runtime === rhs.runtime && lhs.modelID == rhs.modelID && lhs.profile == rhs.profile
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(runtime))
            hasher.combine(modelID)
            hasher.combine(profile)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: LlamaLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try RequestRequirements(request).check(against: model.declaredCapabilities)
        throw LlamaEngineError.engineUnavailable("the native bridge is not built yet (P2)")
    }
}

/// Capabilities a request needs, found before any computation so that an
/// unsupported request fails explicitly instead of being approximated.
struct RequestRequirements: Equatable {
    var capabilities: [LanguageModelCapabilities.Capability] = []
    var reasons: [String] = []

    init(_ request: LanguageModelExecutorGenerationRequest) {
        if request.schema != nil {
            add(.guidedGeneration, "the request has a response schema")
        }
        if !request.enabledToolDefinitions.isEmpty {
            add(.toolCalling, "the request enables \(request.enabledToolDefinitions.count) tool(s)")
        } else if request.generationOptions.toolCallingMode?.kind == .required {
            add(.toolCalling, "the request requires a tool call")
        }
        if request.contextOptions.reasoningLevel != nil {
            add(.reasoning, "the request sets a reasoning level")
        }
        for entry in request.transcript {
            switch entry {
            case .reasoning:
                add(.reasoning, "the transcript contains reasoning")
            case .instructions(let instructions):
                if !instructions.toolDefinitions.isEmpty {
                    add(.toolCalling, "the instructions define tools")
                }
                scan(instructions.segments)
            case .prompt(let prompt):
                scan(prompt.segments)
            case .toolCalls:
                add(.toolCalling, "the transcript contains tool calls")
            case .toolOutput(let output):
                add(.toolCalling, "the transcript contains tool output")
                scan(output.segments)
            case .response(let response):
                scan(response.segments)
            @unknown default:
                break
            }
        }
    }

    private mutating func scan(_ segments: [Transcript.Segment]) {
        for segment in segments {
            if case .attachment = segment {
                add(.vision, "the transcript contains an image")
            }
        }
    }

    private mutating func add(_ capability: LanguageModelCapabilities.Capability, _ reason: String) {
        if !capabilities.contains(capability) {
            capabilities.append(capability)
            reasons.append(reason)
        }
    }

    /// Throws `LanguageModelError.unsupportedCapability` for the first needed
    /// capability that the model does not declare.
    func check(against declared: [LanguageModelCapabilities.Capability]) throws {
        for (capability, reason) in zip(capabilities, reasons) where !declared.contains(capability) {
            throw LanguageModelError.unsupportedCapability(.init(
                capability: capability,
                debugDescription: "\(reason), but this llama.cpp model does not declare that capability"))
        }
    }
}
