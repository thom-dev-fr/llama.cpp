import Foundation
import FoundationModels
import LlamaEngine
@testable import LlamaFoundationModels
import Testing

// P0: the skeleton conforms to the SDK protocols and refuses explicitly.
// These tests do not validate any capability.

private func request(
    _ entries: [Transcript.Entry],
    tools: [Transcript.ToolDefinition] = [],
    schema: GenerationSchema? = nil,
    options: GenerationOptions = GenerationOptions(),
    context: ContextOptions = ContextOptions()
) -> LanguageModelExecutorGenerationRequest {
    LanguageModelExecutorGenerationRequest(
        id: UUID(), transcript: Transcript(entries: entries), enabledTools: tools, schema: schema,
        generationOptions: options, contextOptions: context, metadata: [:])
}

private func prompt(_ text: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
}

@Generable private struct Answer {
    var value: Int
}

@Suite struct SkeletonConformanceTests {
    let runtime = try! LlamaRuntime()

    @Test func configurationIdentityFollowsTheRuntimeInstance() throws {
        let other = try LlamaRuntime()
        let a = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m")).executorConfiguration
        let b = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m")).executorConfiguration
        let c = LlamaLanguageModel(runtime: other, modelID: LlamaModelID("m")).executorConfiguration
        let d = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m"),
                                   profile: LlamaLoadProfile(contextSize: 8192)).executorConfiguration
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(a != d)
        _ = try LlamaLanguageModelExecutor(configuration: a)
    }

    @Test func skeletonDeclaresNoCapability() {
        let model = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m"))
        for capability in [LanguageModelCapabilities.Capability.guidedGeneration, .toolCalling, .reasoning, .vision] {
            #expect(!model.capabilities.contains(capability))
        }
    }

    @Test func requirementsAreDetectedBeforeComputation() {
        let tool = Transcript.ToolDefinition(name: "add", description: "adds", parameters: Answer.generationSchema)
        let r = RequestRequirements(request(
            [prompt("hi"), .reasoning(Transcript.Reasoning(segments: []))],
            tools: [tool], schema: Answer.generationSchema,
            context: ContextOptions(reasoningLevel: .light)))
        #expect(r.capabilities == [.guidedGeneration, .toolCalling, .reasoning])

        let plain = RequestRequirements(request([prompt("hi")]))
        #expect(plain.capabilities.isEmpty)

        let required = RequestRequirements(request([prompt("hi")],
            options: GenerationOptions(toolCallingMode: .required)))
        #expect(required.capabilities == [.toolCalling])
    }

    @Test func textRequestFailsExplicitly() async throws {
        let model = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m"))
        let executor = try LlamaLanguageModelExecutor(configuration: model.executorConfiguration)
        await #expect(throws: LlamaEngineError.self) {
            try await executor.respond(to: request([prompt("hi")]), model: model,
                                       streamingInto: LanguageModelExecutorGenerationChannel())
        }
    }

    @Test func undeclaredCapabilityIsRefused() async throws {
        let model = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m"))
        let executor = try LlamaLanguageModelExecutor(configuration: model.executorConfiguration)
        do {
            try await executor.respond(to: request([prompt("hi")], schema: Answer.generationSchema), model: model,
                                       streamingInto: LanguageModelExecutorGenerationChannel())
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .guidedGeneration)
        }
    }

    @Test func sessionSurfacesTheFailure() async throws {
        let model = LlamaLanguageModel(runtime: runtime, modelID: LlamaModelID("m"))
        let session = LanguageModelSession(model: model)
        do {
            _ = try await session.respond(to: "hi")
            Issue.record("expected an error")
        } catch {
            // Records how Foundation Models forwards an executor error (P0 evidence).
            print("P0 session error: \(type(of: error)): \(error)")
        }
        #expect(!session.isResponding)
    }
}
