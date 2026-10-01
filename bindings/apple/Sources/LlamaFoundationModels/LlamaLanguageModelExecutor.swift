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

    /// Optional: loads the model in the background so that the first answer
    /// starts sooner. `respond` loads it anyway when needed.
    public func prewarm(model: LlamaLanguageModel, transcript: Transcript) {
        let runtime = model.runtime, id = model.modelID, profile = model.profile
        Task.detached(priority: .utility) {
            try? await runtime.load(id, profile: profile)
        }
    }

    public nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: LlamaLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await Responder(model: model, backend: model.backend).respond(to: request, streamingInto: channel)
    }
}

/// One `respond`: checks, translation, submission, streaming, errors.
struct Responder {
    let model: LlamaLanguageModel
    let backend: any LlamaChatBackend

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let monitor = model.monitor
        monitor?.begin(request.id)
        defer { monitor?.end(request.id) }

        // Refusals before any computation.
        let capabilities = model.capabilitySet
        let requirements = RequestRequirements(request)
        try requirements.check(against: capabilities)
        if requirements.capabilities.contains(.vision) {
            guard model.profile.usesProjector, backend.artifact(model.modelID)?.projector != nil else {
                throw LanguageModelError.unsupported(.vision, "the transcript contains an image, but the load profile "
                    + "of '\(model.modelID)' does not load a multimodal projector")
            }
        }
        let traits = ModelTraits(capabilities: capabilities) { [backend, model] in
            try await TemplateCapabilities.supportsReasoningEffort(backend: backend, model: model)
        }
        let engineRequest = try await RequestTranslation(request: request, traits: traits).build()
        let schemaName = engineRequest.schemaName

        let events: any LlamaChatEvents
        do {
            events = try await backend.chat(model: model.modelID, profile: model.profile, body: engineRequest.body.data,
                                            attachments: engineRequest.attachments)
        } catch {
            throw translateEngineError(error, schemaName: schemaName)
        }
        // Leaving early (an error, a cancelled task) ends the native request.
        defer { events.cancel() }

        var stream = StreamTranslation()
        do {
            while let event = try await events.next() {
                if event.kind == .success {
                    if event.data != Data("null".utf8), !event.data.isEmpty {
                        for event in try stream.translate(payload: event.data) {
                            await channel.send(event)
                        }
                    }
                    break
                }
                guard event.kind == .payload else { continue }
                for event in try stream.translate(payload: event.data) {
                    await channel.send(event)
                }
                monitor?.update { state in
                    state.context = stream.report ?? state.context
                    state.isContextLive = stream.report != nil
                    if stream.hasGenerated {
                        state.phase = .generating
                        state.promptProgress = 1
                    } else if let progress = stream.promptProgress {
                        state.phase = .processingPrompt
                        state.promptProgress = progress
                    }
                }
            }
            for event in try stream.finish() {
                await channel.send(event)
            }
            monitor?.update { state in
                state.context = stream.report ?? state.context
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw translateEngineError(error, schemaName: schemaName)
        }
    }
}

/// Engine properties of the chat template, asked when a request needs them
/// (the instance is loaded by then, so the call is cheap).
enum TemplateCapabilities {
    static func supportsReasoningEffort(backend: any LlamaChatBackend, model: LlamaLanguageModel) async throws -> Bool {
        let data: Data
        do {
            data = try await backend.properties(model: model.modelID, profile: model.profile)
        } catch {
            throw translateEngineError(error, schemaName: nil)
        }
        let properties = try? JSONValue(parsing: data)
        guard case let .bool(value)? = properties?["chat_template_caps"]?["supports_reasoning_effort"] else {
            throw LlamaLanguageModelError.invalidEngineOutput(
                "the engine properties have no chat_template_caps: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return value
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
    func check(against declared: Set<LanguageModelCapabilities.Capability>) throws {
        for (capability, reason) in zip(capabilities, reasons) where !declared.contains(capability) {
            throw LanguageModelError.unsupported(capability,
                "\(reason), but this llama.cpp model does not declare that capability")
        }
    }
}
