import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
@testable import LlamaEngine
@testable import LlamaFoundationModels
import Testing

// P5: each capability the adapter announces, with a real model: Qwen3.5-2B
// Q4_K_M and its projector (the catalog entry). Opt-in, the files are large:
//
//   TEST_RUNNER_LLAMA_QWEN_DIR=<directory with Qwen3.5-2B-Q4_K_M.gguf and mmproj-BF16.gguf>
//   TEST_RUNNER_LLAMA_QWEN_OFFLOAD=none|all   (default: all)
//
// Answers are checked on facts a correct answer must contain, not on wording.

private let directory = ProcessInfo.processInfo.environment["LLAMA_QWEN_DIR"].map { URL(fileURLWithPath: $0) }
private let enabled = directory != nil
private let qwen = LlamaModelID("qwen3.5-2b-q4_k_m")
private let offload: LlamaComputeConfiguration.Offload =
    ProcessInfo.processInfo.environment["LLAMA_QWEN_OFFLOAD"] == "none" ? .none : .all
private let profile = LlamaLoadProfile(contextSize: 4096, compute: LlamaComputeConfiguration(offload: offload),
                                       usesProjector: true)
private let noReasoning = ContextOptions(reasoningLevel: .custom("none"))

private let image = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../tools/mtmd/test-1.jpeg").standardizedFileURL

/// One runtime for the suite: the model is loaded once.
private let shared: LlamaRuntime? = {
    guard let directory else { return nil }
    let runtime = try! LlamaRuntime(configuration: LlamaRuntime.Configuration(
        limits: LlamaRuntime.Limits(maximumResidentModels: 2, maximumActiveGenerations: 2)))
    try! runtime.register(LlamaModelArtifact(id: qwen, weights: [directory.appendingPathComponent("Qwen3.5-2B-Q4_K_M.gguf")],
                                             projector: directory.appendingPathComponent("mmproj-BF16.gguf")))
    return runtime
}()

private func model(_ monitor: LlamaGenerationMonitor? = nil, profile: LlamaLoadProfile = profile) -> LlamaLanguageModel {
    LlamaLanguageModel(runtime: shared!, modelID: qwen, profile: profile,
                       capabilities: [.guidedGeneration, .toolCalling, .reasoning, .vision], monitor: monitor)
}

@Generable struct CityFacts {
    var name: String
    var country: String
    @Guide(description: "population of the city", .range(0...50_000_000)) var population: Int
    @Guide(description: "famous landmarks", .count(3)) var landmarks: [String]
}

/// Evaluates "a op b" for integers; anything else is "unknown".
struct ArithmeticTool: Tool {
    let name = "calculate"
    let description = "Evaluates an arithmetic expression with two integers and one operator among + - * /"
    @Generable struct Arguments {
        @Guide(description: "for example 6*7") var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        let text = arguments.expression.replacingOccurrences(of: " ", with: "")
        for op in ["*", "+", "-", "/"] {
            let parts = text.components(separatedBy: op)
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                switch op {
                case "*": return String(a * b)
                case "+": return String(a + b)
                case "-": return String(a - b)
                default: return b == 0 ? "undefined" : String(a / b)
                }
            }
        }
        return "unknown"
    }
}

private func kinds(_ transcript: Transcript) -> [String] {
    transcript.map { entry in
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .reasoning: "reasoning"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .response: "response"
        @unknown default: "other"
        }
    }
}

private func elapsed(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite(.serialized, .enabled(if: enabled, "set TEST_RUNNER_LLAMA_QWEN_DIR")) struct QwenTests {
    @Test func text() async throws {
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(monitor))
        let start = ContinuousClock.now
        var firstToken: Double?
        var answer = ""
        for try await snapshot in session.streamResponse(
            to: "What is the capital of France? Answer with one word.",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32), contextOptions: noReasoning) {
            if firstToken == nil { firstToken = elapsed(since: start) }
            answer = snapshot.content
        }
        let total = elapsed(since: start)
        #expect(answer.contains("Paris"))
        let usage = session.usage
        print("P5 qwen text: '\(answer)' first fragment \(firstToken ?? -1) s, total \(total) s, prompt \(usage.input.totalTokenCount), output \(usage.output.totalTokenCount)")
        #expect(monitor.state.context?.contextSize == 4096)
    }

    @Test func reasoningIsSeparate() async throws {
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(to: "What is 17 + 25? Answer with the number only.",
                                                 options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1500))
        let reasoning = session.transcript.compactMap { entry -> String? in
            guard case .reasoning(let r) = entry else { return nil }
            return r.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
        }
        print("P5 qwen reasoning: \(reasoning.first?.count ?? 0) characters, answer '\(response.content)', reasoning tokens \(session.usage.output.reasoningTokenCount)")
        #expect(!(reasoning.first ?? "").isEmpty)
        #expect(response.content.contains("42"))
        #expect(!response.content.contains("<think>") && !response.content.contains("</think>"))
        #expect(session.usage.output.reasoningTokenCount > 0)
    }

    @Test func reasoningLevelWithoutTemplateSupportIsRefused() async throws {
        do {
            _ = try await LanguageModelSession(model: model()).respond(to: "hi", contextOptions: ContextOptions(reasoningLevel: .deep))
            Issue.record("expected a refusal")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .reasoning)
        }
    }

    @Test func structuredOutputStreams() async throws {
        let session = LanguageModelSession(model: model())
        var partials = 0
        var last: CityFacts.PartiallyGenerated?
        for try await snapshot in session.streamResponse(
            to: "Give facts about Paris.", generating: CityFacts.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))) {
            partials += 1
            last = snapshot.content
        }
        let facts = try #require(last)
        print("P5 qwen structured: \(partials) snapshots, \(String(describing: facts))")
        #expect(partials > 3)
        #expect(facts.name?.contains("Paris") == true)
        #expect(facts.country?.contains("France") == true)
        #expect(facts.landmarks?.count == 3)
    }

    @Test func reasoningWithStructuredOutput() async throws {
        let session = LanguageModelSession(model: model())
        // Thinking with the schema in the prompt, this 2B model often reasons about the schema until the
        // token limit (see the P5 report); the grammar alone enforces the format.
        let response = try await session.respond(to: "What is 6 times 7?", generating: Total.self,
                                                 options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1500),
                                                 contextOptions: ContextOptions(includeSchemaInPrompt: false))
        #expect(response.content.value == 42)
        #expect(kinds(session.transcript).contains("reasoning"))
    }

    @Test func toolLoop() async throws {
        let session = LanguageModelSession(model: model(), tools: [ArithmeticTool(), LookupTool()],
                                           instructions: "Use the tools to answer. Do not compute or guess yourself.")
        let response = try await session.respond(
            to: "What is 6*7, and what is the price of a pen?",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400), contextOptions: noReasoning)
        let outputs = session.transcript.compactMap { entry -> String? in
            guard case .toolOutput(let o) = entry else { return nil }
            return "\(o.toolName):" + o.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
        }
        print("P5 qwen tools: \(kinds(session.transcript)) outputs \(outputs) answer '\(response.content)'")
        #expect(outputs.contains("calculate:42"))
        #expect(outputs.contains("lookup:3 EUR"))
        #expect(response.content.contains("42"))
        #expect(response.content.contains("3"))
    }

    @Test func toolsWithStructuredOutput() async throws {
        let session = LanguageModelSession(model: model(), tools: [ArithmeticTool()])
        let response = try await session.respond(
            to: "Compute 123*4 with the calculator and give the result.", generating: Total.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400, toolCallingMode: .required),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none")))
        print("P5 qwen tools + structured: \(kinds(session.transcript)) value \(response.content.value)")
        #expect(kinds(session.transcript).contains("toolCalls"))
        #expect(response.content.value == 492)
    }

    @Test func vision() async throws {
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64), contextOptions: noReasoning) {
            "What is the main headline of this newspaper?"
            Attachment(imageURL: image)
        }
        print("P5 qwen vision: '\(response.content)', prompt tokens \(session.usage.input.totalTokenCount)")
        #expect(response.content.uppercased().contains("MOON"))
        #expect(session.usage.input.totalTokenCount > 100) // the image is in the prompt
    }

    @Test func visionKeepsTheOrientation() async throws {
        // the same page turned on its side by its orientation: still readable once upright
        let source = try #require(CGImageSourceCreateWithURL(image as CFURL, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = try ImageEncoding.oriented(cgImage, .left)
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64), contextOptions: noReasoning) {
            "What is the main headline of this newspaper?"
            Attachment(rotated, orientation: .right)
        }
        print("P5 qwen vision (orientation): '\(response.content)'")
        #expect(response.content.uppercased().contains("MOON"))
    }

    @Test func twoSessionsAtOnce() async throws {
        let a = LanguageModelSession(model: model())
        let b = LanguageModelSession(model: model())
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32)
        async let x = a.respond(to: "What is the capital of Italy? One word.", options: options, contextOptions: noReasoning)
        async let y = b.respond(to: "What is the capital of Spain? One word.", options: options, contextOptions: noReasoning)
        let (rx, ry) = try await (x, y)
        #expect(rx.content.contains("Rome"))
        #expect(ry.content.contains("Madrid"))
        #expect(shared!.snapshot()[qwen]?.instances.filter { $0.profile == profile }.count == 1)
    }

    @Test func cancellationIsPrompt() async throws {
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(monitor))
        let task = Task {
            try await session.respond(to: "Count from 1 to 2000, separated by commas.",
                                      options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 3000),
                                      contextOptions: noReasoning)
        }
        try await until(.seconds(120)) { (monitor.state.context?.generatedTokens ?? 0) > 20 }
        let start = ContinuousClock.now
        task.cancel()
        let result = try await within(.seconds(10)) { await task.result }
        let delay = elapsed(since: start)
        print("P5 qwen cancellation: ended after \(delay) s")
        guard case .failure(let error)? = result else {
            Issue.record("not cancelled: \(String(describing: result))")
            return
        }
        #expect(error is CancellationError)
        #expect(delay < 2)
        try await until { shared!.snapshot().admission.activeGenerations == 0 }
    }

    @Test func contextFullBeforeAndDuringGeneration() async throws {
        let small = LlamaLoadProfile(contextSize: 256, compute: LlamaComputeConfiguration(offload: offload))
        let session = LanguageModelSession(model: model(profile: small))
        do {
            _ = try await session.respond(to: String(repeating: "This sentence fills the context. ", count: 60),
                                          contextOptions: noReasoning)
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 256)
            #expect(info.debugDescription.contains("prompt"))
        }
        do {
            _ = try await session.respond(to: "Count from 1 to 500, separated by commas.",
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 2000),
                                          contextOptions: noReasoning)
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 256)
            #expect(info.debugDescription.contains("generation"))
        }
        // a budget reached is an answer, not an error
        let short = try await session.respond(to: "Count from 1 to 500, separated by commas.",
                                              options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 10),
                                              contextOptions: noReasoning)
        #expect(!short.content.isEmpty)
        try await shared!.unload(qwen)
    }
}
