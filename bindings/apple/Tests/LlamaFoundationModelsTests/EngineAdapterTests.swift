import Foundation
import FoundationModels
@testable import LlamaEngine
@testable import LlamaFoundationModels
import Testing

// P5: the adapter on the real engine with the small test model (CPU): what
// does not depend on the model's quality — streaming, grammar-constrained
// output, the engine's strict schema check, context overflow, sharing,
// unload. The capabilities of a real model are in QwenTests.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../tools/server/tests/tmp/stories15M-q4_0.gguf").standardizedFileURL

private let stories = LlamaModelID("stories")
private let profile = LlamaLoadProfile(contextSize: 128, compute: LlamaComputeConfiguration(offload: .none),
                                       chatTemplate: "chatml")

private func runtime(_ limits: LlamaRuntime.Limits = LlamaRuntime.Limits()) throws -> LlamaRuntime {
    let runtime = try LlamaRuntime(configuration: LlamaRuntime.Configuration(limits: limits))
    try runtime.register(LlamaModelArtifact(id: stories, weights: [fixture]))
    return runtime
}

private func model(_ runtime: LlamaRuntime, monitor: LlamaGenerationMonitor? = nil,
                   profile: LlamaLoadProfile = profile) -> LlamaLanguageModel {
    LlamaLanguageModel(runtime: runtime, modelID: stories, profile: profile, capabilities: [.guidedGeneration, .toolCalling],
                       monitor: monitor)
}

private let greedy = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 8)

@Generable enum Weather { case sunny, rainy, windy }

@Generable struct Forecast {
    var weather: Weather
    @Guide(.range(-20...45)) var temperature: Int
    @Guide(.count(2)) var flags: [Bool]
}

@Generable struct Strict {
    @Guide(.pattern(/(?=a)a/)) var text: String
}

/// The Qwen3.5 template of the repository: its XML tool call format writes a
/// string argument as raw text.
private let qwenTemplate = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../models/templates/Qwen3.5-4B.jinja").standardizedFileURL

/// A string argument with a pattern.
struct CodeTool: Tool {
    let name = "check_code"
    let description = "Checks a product code."
    @Generable struct Arguments {
        @Guide(.pattern(/[A-Z]{3}/)) var code: String
    }

    func call(arguments: Arguments) async throws -> String { "ok" }
}

@Suite(.serialized) struct EngineAdapterTests {
    @Test func textStreamsFromTheEngine() async throws {
        let runtime = try runtime()
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(runtime, monitor: monitor))
        var snapshots = 0
        var text = ""
        for try await snapshot in session.streamResponse(to: "Once upon a time", options: greedy) {
            snapshots += 1
            text = snapshot.content
        }
        #expect(!text.isEmpty)
        #expect(snapshots > 1)
        #expect(session.usage.output.totalTokenCount == 8)
        #expect(session.usage.input.totalTokenCount > 0)
        let state = monitor.state
        #expect(state.phase == .idle && !state.isContextLive)
        #expect(state.context?.contextSize == 128)
        #expect(state.context?.generatedTokens == 8)
        #expect(state.context?.occupiedTokens == (state.context?.promptTokens ?? 0) + 8)

        // the same request again: the whole transcript is sent, the engine reuses its cached prefix
        _ = try await session.respond(to: "The end", options: greedy)
        #expect(session.usage.input.cachedTokenCount > 0)
        await runtime.shutdown()
    }

    @Test func guidedGenerationIsEnforcedByTheGrammar() async throws {
        let runtime = try runtime()
        // A template without generation prompt: the engine feeds a generation
        // prompt to the grammar, and with the fixture's vocabulary the chatml
        // markers are not special tokens (see the P5 report).
        let plain = LlamaLoadProfile(contextSize: 256, compute: LlamaComputeConfiguration(offload: .none),
                                     chatTemplate: "{% for message in messages %}{{ message.content }}\n{% endfor %}")
        let session = LanguageModelSession(model: model(runtime, profile: plain))
        var partials = 0
        var forecast: Forecast.PartiallyGenerated?
        // the schema is left out of the prompt: the fixture's context is 128 tokens
        for try await snapshot in session.streamResponse(to: "Weather?", generating: Forecast.self, includeSchemaInPrompt: false,
                                                         options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 100)) {
            partials += 1
            forecast = snapshot.content
        }
        let result = try #require(forecast)
        #expect(partials > 1)
        #expect(result.weather != nil)
        #expect((-20...45).contains(try #require(result.temperature)))
        #expect(result.flags?.count == 2)
        await runtime.shutdown()
    }

    @Test func engineRefusesAnUnsupportedPattern() async throws {
        let runtime = try runtime()
        do {
            _ = try await LanguageModelSession(model: model(runtime)).respond(to: "x", generating: Strict.self)
            Issue.record("expected a refusal")
        } catch let LanguageModelError.unsupportedGenerationGuide(info) {
            #expect(info.schemaName == "Strict")
            #expect(info.debugDescription.contains("text"))
            #expect(info.debugDescription.contains("unsupported group syntax"))
        }
        await runtime.shutdown()
    }

    @Test func toolsWithAResponseFormatNeedAFormatThatCombinesThem() async throws {
        let runtime = try runtime()
        do {
            _ = try await LanguageModelSession(model: model(runtime), tools: [CalculatorTool()])
                .respond(to: "x", generating: Forecast.self, options: greedy)
            Issue.record("expected a refusal")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .toolCalling)
            #expect(info.debugDescription.contains("tools combined with a response format"))
        }
        await runtime.shutdown()
    }

    @Test func toolArgumentConstraintTheFormatCannotEnforceIsRefused() async throws {
        let runtime = try runtime()
        let qwen = LlamaLoadProfile(contextSize: 1024, compute: LlamaComputeConfiguration(offload: .none),
                                    chatTemplate: try String(contentsOf: qwenTemplate, encoding: .utf8))
        do {
            _ = try await LanguageModelSession(model: model(runtime, profile: qwen), tools: [CodeTool()])
                .respond(to: "x", options: greedy)
            Issue.record("expected a refusal")
        } catch let LanguageModelError.unsupportedGenerationGuide(info) {
            #expect(info.schemaName == "check_code")
            #expect(info.debugDescription.contains("parameter code has pattern"))
        }
        // the same tool disallowed: nothing to constrain
        let response = try await LanguageModelSession(model: model(runtime, profile: qwen), tools: [CodeTool()])
            .respond(to: "x", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 8, toolCallingMode: .disallowed))
        #expect(!response.content.isEmpty)
        await runtime.shutdown()
    }

    @Test func templateCapabilitiesAreRead() async throws {
        let runtime = try runtime()
        let data = try await runtime.properties(model: stories, profile: profile)
        let caps = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["chat_template_caps"] as? [String: Any]
        #expect(caps?["supports_reasoning_effort"] as? Bool == false, "\(String(decoding: data.prefix(300), as: UTF8.self))")
        await runtime.shutdown()
    }

    @Test func promptLargerThanTheContextFails() async throws {
        let runtime = try runtime()
        let session = LanguageModelSession(model: model(runtime))
        do {
            _ = try await session.respond(to: String(repeating: "Once upon a time there was a cat. ", count: 30), options: greedy)
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 128)
            #expect(info.tokenCount > 128)
            #expect(info.debugDescription.contains("prompt"))
        }
        // the session goes on
        #expect(try await !session.respond(to: "Hello", options: greedy).content.isEmpty)
        await runtime.shutdown()
    }

    @Test func contextFullDuringGenerationIsNotAnEndOfAnswer() async throws {
        let runtime = try runtime()
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(runtime, monitor: monitor))
        do {
            // about 100 prompt tokens: the 128-token context fills before 200 generated tokens
            _ = try await session.respond(to: String(repeating: "The cat sat. ", count: 20),
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200))
            Issue.record("expected an error (the model ended its answer before the context filled)")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 128)
            #expect(info.debugDescription.contains("generation"))
        }
        #expect(monitor.state.context?.occupiedTokens == 128 || monitor.state.context?.occupiedTokens == 127)
        await runtime.shutdown()
    }

    @Test func twoSessionsShareOneLoadedModel() async throws {
        let runtime = try runtime(LlamaRuntime.Limits(maximumActiveGenerations: 2))
        let a = LanguageModelSession(model: model(runtime))
        let b = LanguageModelSession(model: model(runtime))
        async let first = a.respond(to: "Once upon a time", options: greedy)
        async let second = b.respond(to: "Lily had a dog", options: greedy)
        let (x, y) = try await (first, second)
        #expect(!x.content.isEmpty && !y.content.isEmpty)
        #expect(runtime.snapshot()[stories]?.instances.count == 1)
        #expect(a.transcript.count == 2 && b.transcript.count == 2)
        await runtime.shutdown()
    }

    @Test func unloadEndsTheAnswerAndTheNextRequestReloads() async throws {
        let runtime = try runtime()
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(runtime, monitor: monitor, profile: LlamaLoadProfile(
            contextSize: 4096, compute: LlamaComputeConfiguration(offload: .none), chatTemplate: "chatml")))
        let answer = Task {
            try await session.respond(to: "Once upon a time", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 3000))
        }
        try await until(.seconds(60)) { monitor.state.phase == .generating }
        try await runtime.unload(stories)
        switch await answer.result {
        case .failure(let error):
            #expect(error as? LlamaEngineError == .unloaded(stories), "\(error)")
            #expect(session.transcript.isEmpty)
        case .success:
            // the model ended its answer before the unload: nothing to check
            print("P5 unload: the answer ended first")
        }
        #expect(try await !session.respond(to: "Hello", options: greedy).content.isEmpty)
        await runtime.shutdown()
    }
}
