import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
@testable import LlamaEngine
@testable import LlamaFoundationModels
import Testing

// P5: the real adapter (LlamaLanguageModel, executor, translations) driven by
// Foundation Models sessions, with a controlled engine boundary. Every engine
// request is recorded; the engine answers are scripted.

private let modelID = LlamaModelID("m")
private let allCapabilities: Set<LlamaModelCatalog.Capability> = [.guidedGeneration, .toolCalling, .reasoning, .vision]
private let sharedRuntime = try! LlamaRuntime()

private func model(_ backend: ScriptedBackend, capabilities: Set<LlamaModelCatalog.Capability>? = allCapabilities,
                   profile: LlamaLoadProfile = LlamaLoadProfile(usesProjector: true),
                   monitor: LlamaGenerationMonitor? = nil) -> LlamaLanguageModel {
    if backend.artifacts[modelID] == nil {
        backend.artifacts[modelID] = LlamaModelArtifact(id: modelID, weights: [URL(fileURLWithPath: "/m.gguf")],
                                                        projector: URL(fileURLWithPath: "/p.gguf"))
    }
    return LlamaLanguageModel(runtime: sharedRuntime, modelID: modelID, profile: profile, capabilities: capabilities,
                              monitor: monitor, backend: backend)
}

private func messages(_ submission: ScriptedBackend.Submission) -> [[String: Any]] {
    submission.json["messages"] as? [[String: Any]] ?? []
}

private func request(_ entries: [Transcript.Entry], tools: [Transcript.ToolDefinition] = [],
                     schema: GenerationSchema? = nil, options: GenerationOptions = GenerationOptions(),
                     context: ContextOptions = ContextOptions()) -> LanguageModelExecutorGenerationRequest {
    LanguageModelExecutorGenerationRequest(id: UUID(), transcript: Transcript(entries: entries), enabledTools: tools,
                                           schema: schema, generationOptions: options, contextOptions: context, metadata: [:])
}

private func prompt(_ text: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
}

private func translate(_ request: LanguageModelExecutorGenerationRequest,
                       capabilities: Set<LanguageModelCapabilities.Capability> = [.guidedGeneration, .toolCalling, .reasoning, .vision],
                       reasoningEffort: Bool = false) async throws -> [String: Any] {
    let traits = ModelTraits(capabilities: capabilities) { reasoningEffort }
    let built = try await RequestTranslation(request: request, traits: traits).build()
    return try JSONSerialization.jsonObject(with: built.body.data) as! [String: Any]
}

/// A deterministic local tool.
struct CalculatorTool: Tool {
    let name = "calculate"
    let description = "Evaluates an arithmetic expression"
    @Generable struct Arguments {
        @Guide(description: "an expression such as 6*7") var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        ["6*7": "42", "1+1": "2"][arguments.expression] ?? "unknown"
    }
}

struct LookupTool: Tool {
    let name = "lookup"
    let description = "Finds the price of a catalog item"
    @Generable struct Arguments {
        var item: String
    }

    func call(arguments: Arguments) async throws -> String {
        arguments.item == "pen" ? "3 EUR" : "not found"
    }
}

@Generable struct Total {
    @Guide(description: "the result", .range(0...1000)) var value: Int
    var unit: String?
}

@Generable struct Coded {
    var zeta: String
    @Guide(.pattern(/\d{3}-[A-Z]+/)) var code: String
    var alpha: Int?
}
@Generable struct Measure {
    @Guide(.range(0.5...2.5)) var weight: Double
}
@Generable struct Word {
    @Guide(.pattern(/\D+/)) var text: String
}

@Suite(.serialized) struct AdapterTests {
    // MARK: Text and streaming

    @Test func textStreamsInOrderWithUsage() async throws {
        let backend = ScriptedBackend([.init(events: [
            .progress(processed: 4, total: 10), .progress(processed: 10, total: 10),
            .text("Bon", decoded: 1), .text("jour é 🌍", decoded: 3), .text("!", decoded: 4),
            .finish("stop", decoded: 5), .success,
        ])])
        let session = LanguageModelSession(model: model(backend))
        var snapshots: [String] = []
        for try await snapshot in session.streamResponse(to: "Salut") {
            snapshots.append(snapshot.content)
        }
        #expect(snapshots.last == "Bonjour é 🌍!")
        // snapshots grow by appended deltas (the framework may coalesce some)
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $1.hasPrefix($0) })
        let response = try #require(session.transcript.last)
        guard case .response(let r) = response else {
            Issue.record("expected a response entry")
            return
        }
        #expect(r.segments.count == 1)
        #expect(session.usage.input.totalTokenCount == 10)
        #expect(session.usage.output.totalTokenCount == 5)

        let body = try #require(backend.submissions.first).json
        #expect(body["stream"] as? Bool == true)
        #expect(body["fail_on_context_full"] as? Bool == true)
        #expect(body["return_context"] as? Bool == true)
        #expect(body["return_progress"] as? Bool == true)
        #expect(body["strict_json_schema"] as? Bool == true)
        #expect(body["tools"] == nil)
        #expect(body["samplers"] == nil && body["temperature"] == nil && body["seed"] == nil)
        #expect(messages(backend.submissions[0]).count == 1)
        #expect(messages(backend.submissions[0])[0]["content"] as? String == "Salut")
    }

    @Test func serializationIsDeterministic() async throws {
        let tools = [Transcript.ToolDefinition(tool: CalculatorTool()), Transcript.ToolDefinition(tool: LookupTool())]
        let r = request([prompt("hi")], tools: tools, schema: Total.generationSchema)
        let traits = ModelTraits(capabilities: [.guidedGeneration, .toolCalling]) { false }
        let a = try await RequestTranslation(request: r, traits: traits).build().body.serialized
        let b = try await RequestTranslation(request: r, traits: traits).build().body.serialized
        #expect(a == b)
    }

    // MARK: Transcript

    @Test func completeTranscriptIsTranslatedEveryTime() async throws {
        let backend = ScriptedBackend([.init(events: [.text("ok", decoded: 1), .success])])
        let image = try testImage(width: 4, height: 2)
        let transcript = Transcript(entries: [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: "Be brief."))],
                                                  toolDefinitions: [Transcript.ToolDefinition(tool: CalculatorTool())])),
            prompt("Compute 1+1"),
            .reasoning(Transcript.Reasoning(segments: [.text(.init(content: "I should call the tool"))])),
            .toolCalls(Transcript.ToolCalls([
                Transcript.ToolCall(id: "call-1", toolName: "calculate", arguments: try GeneratedContent(json: #"{"expression":"1+1"}"#)),
            ])),
            .toolOutput(Transcript.ToolOutput(id: "call-1", toolName: "calculate", segments: [.text(.init(content: "2"))])),
            .response(Transcript.Response(segments: [.text(.init(content: "It is 2."))])),
            .prompt(Transcript.Prompt(segments: [
                .text(.init(content: "Look")),
                .attachment(.init(content: .image(Transcript.ImageAttachment(image, orientation: .right)))),
                .text(.init(content: "What is it?")),
            ])),
            .response(Transcript.Response(segments: [.text(.init(content: "A picture."))])),
        ])
        let session = LanguageModelSession(model: model(backend), tools: [CalculatorTool()], transcript: transcript)
        _ = try await session.respond(to: "Thanks")

        let submission = try #require(backend.submissions.first)
        let m = messages(submission)
        #expect(m.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "assistant", "user", "assistant", "user"])
        #expect(m[0]["content"] as? String == "Be brief.")
        // reasoning goes with the assistant turn it precedes
        #expect(m[2]["reasoning_content"] as? String == "I should call the tool")
        let call = try #require((m[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call-1")
        let function = try #require(call["function"] as? [String: Any])
        #expect(function["name"] as? String == "calculate")
        let arguments = try JSONSerialization.jsonObject(with: Data((function["arguments"] as! String).utf8)) as? [String: String]
        #expect(arguments == ["expression": "1+1"])
        #expect(m[3]["tool_call_id"] as? String == "call-1")
        #expect(m[3]["content"] as? String == "2")
        #expect(m[4]["content"] as? String == "It is 2.")
        // the image keeps its position between the texts
        let parts = try #require(m[5]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url", "text"])
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String == "attachment:image-1")
        #expect(m[7]["content"] as? String == "Thanks")
        // the tools of the session are enabled
        #expect((submission.json["tools"] as? [[String: Any]])?.count == 1)
        #expect(submission.json["tool_choice"] as? String == "auto")

        // the image is owned PNG data, rotated upright (4x2 turned right is 2x4)
        let attachment = try #require(submission.attachments.first)
        #expect(attachment.name == "image-1")
        let decoded = try #require(CGImageSourceCreateWithData(attachment.bytes as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 2 && decoded.height == 4)
    }

    @Test func modelOutputAttachmentsAreRefused() async throws {
        let image = try testImage(width: 2, height: 2)
        let r = request([prompt("hi"), .response(Transcript.Response(segments: [
            .attachment(.init(content: .image(Transcript.ImageAttachment(image)))),
        ])), prompt("again")])
        do {
            _ = try await translate(r)
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedTranscriptContent(info) {
            #expect(info.unsupportedContent.count == 1)
        }
    }

    @Test func twoSessionsKeepTheirOwnHistory() async throws {
        let backend = ScriptedBackend([
            .init(events: [.text("A1", decoded: 1), .success]), .init(events: [.text("B1", decoded: 1), .success]),
            .init(events: [.text("A2", decoded: 1), .success]), .init(events: [.text("B2", decoded: 1), .success]),
        ])
        let a = LanguageModelSession(model: model(backend))
        let b = LanguageModelSession(model: model(backend))
        _ = try await a.respond(to: "a1")
        _ = try await b.respond(to: "b1")
        _ = try await a.respond(to: "a2")
        _ = try await b.respond(to: "b2")
        let contents = backend.submissions.map { messages($0).compactMap { $0["content"] as? String } }
        #expect(contents[2] == ["a1", "A1", "a2"])
        #expect(contents[3] == ["b1", "B1", "b2"])
    }

    // MARK: Options

    @Test func samplingIsTranslatedExactly() async throws {
        let greedy = try await translate(request([prompt("x")], options: GenerationOptions(samplingMode: .greedy, temperature: 0.7)))
        #expect(greedy["samplers"] as? [String] == ["top_k"])
        #expect(greedy["top_k"] as? Int == 1)
        #expect(greedy["temperature"] == nil)

        let topK = try await translate(request([prompt("x")], options: GenerationOptions(
            samplingMode: .random(top: 5, seed: 7), temperature: 0.3, maximumResponseTokens: 9)))
        #expect(topK["samplers"] as? [String] == ["top_k", "temperature"])
        #expect(topK["top_k"] as? Int == 5)
        #expect(topK["seed"] as? Int == 7)
        #expect(topK["temperature"] as? Double == 0.3)
        #expect(topK["max_tokens"] as? Int == 9)

        let topP = try await translate(request([prompt("x")], options: GenerationOptions(
            samplingMode: .random(probabilityThreshold: 0.9, seed: 0xFFFF_FFFE))))
        #expect(topP["samplers"] as? [String] == ["top_p", "temperature"])
        #expect(topP["top_p"] as? Double == 0.9)
        #expect(topP["seed"] as? Int == 0xFFFF_FFFE)
        #expect(topP["temperature"] == nil) // the model's default temperature

        let temperatureOnly = try await translate(request([prompt("x")], options: GenerationOptions(temperature: 0.5)))
        #expect(temperatureOnly["samplers"] == nil)
        #expect(temperatureOnly["temperature"] as? Double == 0.5)
    }

    @Test func unrepresentableOptionsAreRefusedBeforeSubmission() async throws {
        let refused: [(GenerationOptions, String)] = [
            (GenerationOptions(samplingMode: .random(top: 5, seed: 0xFFFF_FFFF)), "seed"),
            (GenerationOptions(samplingMode: .random(top: 5, seed: .max)), "seed"),
            (GenerationOptions(samplingMode: .random(top: 0)), "sampling"),
            (GenerationOptions(samplingMode: .random(probabilityThreshold: 0)), "sampling"),
            (GenerationOptions(temperature: -1), "temperature"),
        ]
        for (options, name) in refused {
            let backend = ScriptedBackend()
            let session = LanguageModelSession(model: model(backend))
            do {
                _ = try await session.respond(to: "x", options: options)
                Issue.record("expected \(name) to be refused")
            } catch let LlamaLanguageModelError.unsupportedOption(option, _) {
                #expect(option == name)
            } catch {
                Issue.record("\(name): \(error)")
            }
            #expect(backend.submissions.isEmpty)
        }
        // GenerationOptions itself drops a non-positive limit (it logs "must be positive")
        #expect(GenerationOptions(maximumResponseTokens: 0).maximumResponseTokens == nil)
    }

    @Test func toolChoiceFollowsTheMode() async throws {
        let tools = [Transcript.ToolDefinition(tool: CalculatorTool())]
        func choice(_ mode: GenerationOptions.ToolCallingMode?, _ entries: [Transcript.Entry] = [prompt("x")]) async throws -> String? {
            try await translate(request(entries, tools: tools, options: GenerationOptions(toolCallingMode: mode)))["tool_choice"] as? String
        }
        #expect(try await choice(nil) == "auto")
        #expect(try await choice(.allowed) == "auto")
        #expect(try await choice(.disallowed) == "none")
        #expect(try await choice(.required) == "required")
        let calls = Transcript.Entry.toolCalls(Transcript.ToolCalls([
            Transcript.ToolCall(id: "c", toolName: "calculate", arguments: try GeneratedContent(json: #"{"expression":"1+1"}"#)),
        ]))
        let output = Transcript.Entry.toolOutput(Transcript.ToolOutput(id: "c", toolName: "calculate", segments: []))
        // the requirement holds for the answer to the last prompt
        #expect(try await choice(.required, [prompt("x"), calls, output]) == "auto")
        #expect(try await choice(.required, [prompt("x"), calls, output, prompt("y")]) == "required")

        do {
            _ = try await translate(request([prompt("x")], options: GenerationOptions(toolCallingMode: .required)))
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .toolCalling)
        }
    }

    @Test func reasoningLevelsAreTranslatedOrRefused() async throws {
        func body(_ level: ContextOptions.ReasoningLevel?, effort: Bool = false,
                  capabilities: Set<LanguageModelCapabilities.Capability> = [.reasoning]) async throws -> [String: Any] {
            try await translate(request([prompt("x")], context: ContextOptions(reasoningLevel: level)),
                                capabilities: capabilities, reasoningEffort: effort)
        }
        // nil keeps the template's default
        let byDefault = try await body(nil)
        #expect(byDefault["chat_template_kwargs"] == nil && byDefault["reasoning_effort"] == nil)
        // a model that does not declare reasoning never thinks
        #expect((try await body(nil, capabilities: [])["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect((try await body(.custom("none"))["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(try await body(.light, effort: true)["reasoning_effort"] as? String == "low")
        #expect(try await body(.moderate, effort: true)["reasoning_effort"] as? String == "medium")
        #expect(try await body(.deep, effort: true)["reasoning_effort"] as? String == "high")
        #expect(try await body(.custom("max"), effort: true)["reasoning_effort"] as? String == "max")
        do {
            _ = try await body(.deep, effort: false)
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .reasoning)
            #expect(info.debugDescription.contains("reasoning_effort"))
        }
    }

    @Test func reasoningLevelAsksTheTemplateOnce() async throws {
        let backend = ScriptedBackend()
        let session = LanguageModelSession(model: model(backend))
        await #expect(throws: LanguageModelError.self) {
            _ = try await session.respond(to: "x", contextOptions: ContextOptions(reasoningLevel: .light))
        }
        #expect(backend.propertyRequests == 1)
        #expect(backend.submissions.isEmpty)
    }

    // MARK: Schemas

    @Test func schemaIsTranslatedStrictlyAndRenderedInThePrompt() async throws {
        let backend = ScriptedBackend([.init(events: [.text(#"{"value": 4"#, decoded: 3), .text("2}", decoded: 4), .success])])
        let session = LanguageModelSession(model: model(backend))
        var partials: [Int?] = []
        for try await snapshot in session.streamResponse(to: "6*7?", generating: Total.self) {
            partials.append(snapshot.content.value)
        }
        #expect(partials.last == 42)

        let body = try #require(backend.submissions.first).json
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["value"])
        #expect(((schema["properties"] as? [String: Any])?["value"] as? [String: Any])?["maximum"] as? Int == 1000)
        // includeSchemaInPrompt (true by default with a Generable type)
        let content = try #require(messages(backend.submissions[0]).last?["content"] as? String)
        #expect(content.hasPrefix("6*7?\n\n\(RequestTranslation.schemaInstruction)"))

        // not rendered when the caller says so
        backend.enqueue(.init(events: [.text(#"{"value": 1}"#, decoded: 1), .success]))
        _ = try await LanguageModelSession(model: model(backend))
            .respond(to: "one", generating: Total.self, includeSchemaInPrompt: false)
        #expect(messages(backend.submissions[1]).last?["content"] as? String == "one")
    }

    @Test func schemaKeepsDeclarationOrderAndAnchorsPatterns() throws {
        let schema = try SchemaTranslation.translate(Coded.generationSchema)
        let text = schema.serialized
        // properties in declaration order, x-order removed
        let zeta = try #require(text.range(of: "\"zeta\"")), code = try #require(text.range(of: "\"code\"")),
            alpha = try #require(text.range(of: "\"alpha\""))
        #expect(zeta.lowerBound < code.lowerBound && code.lowerBound < alpha.lowerBound)
        #expect(!text.contains("x-order"))
        #expect(schema["properties"]?["code"]?["pattern"]?.stringValue == #"^(?:[0-9]{3}\-[A-Z]+)$"#)
        #expect(schema["required"] == ["zeta", "code"])
    }

    @Test func unrepresentableGuidesAreRefusedWithTheirSchema() async throws {
        for (schema, name, fragment) in [(Measure.generationSchema, "Measure", "floating-point"),
                                         (Word.generationSchema, "Word", "\\D")] {
            let backend = ScriptedBackend()
            do {
                _ = try await LanguageModelSession(model: model(backend)).respond(to: "x", schema: schema)
                Issue.record("expected a refusal")
            } catch let LanguageModelError.unsupportedGenerationGuide(info) {
                #expect(info.schemaName == name)
                #expect(info.debugDescription.contains(fragment))
            }
            #expect(backend.submissions.isEmpty)
        }
    }

    @Test func recursiveRootBecomesADefinition() throws {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Node", properties: [
            .init(name: "value", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "next", schema: DynamicGenerationSchema(referenceTo: "Node"), isOptional: true),
        ]), dependencies: [])
        let translated = try SchemaTranslation.translate(schema)
        #expect(translated["$ref"]?.stringValue == "#/$defs/Node")
        #expect(translated["$defs"]?["Node"]?["properties"]?["next"]?["$ref"]?.stringValue == "#/$defs/Node")
        #expect(!translated.serialized.contains(##""$ref":"#""##))
    }

    @Test func engineSchemaRefusalsAreLocalized() async throws {
        let refusals: [(String, String?, LanguageModelCapabilities.Capability?)] = [
            ("response_format: JSON schema conversion failed:\npattern ^(?:(?=a)a)$ of code is not supported", "Total", nil),
            ("parameters of tool calculate: JSON schema conversion failed: x", "calculate", nil),
            ("the chat format of this model does not support tools combined with a response format", nil, .toolCalling),
        ]
        for (message, schemaName, capability) in refusals {
            let backend = ScriptedBackend([.init(submitError: LlamaEngineError.native(
                category: "invalid_request", message: message, details: Data("null".utf8)))])
            do {
                _ = try await LanguageModelSession(model: model(backend), tools: [CalculatorTool()])
                    .respond(to: "x", generating: Total.self)
                Issue.record("expected an error")
            } catch let LanguageModelError.unsupportedGenerationGuide(info) {
                #expect(capability == nil)
                #expect(info.schemaName == schemaName)
                #expect(info.debugDescription == message)
            } catch let LanguageModelError.unsupportedCapability(info) {
                #expect(info.capability == capability)
            }
        }
    }

    // MARK: Tools

    @Test func toolLoopWithFragmentedArgumentsAndTwoTools() async throws {
        let backend = ScriptedBackend([
            .init(events: [
                .reasoning("Need both tools.", decoded: 3),
                .toolCall(index: 0, id: "c1", name: "calculate", arguments: #"{"expr"#, decoded: 4),
                .toolCall(index: 0, arguments: #"ession": "6*7"}"#, decoded: 6),
                .toolCall(index: 1, id: "c2", name: "lookup", arguments: #"{"item":"#, decoded: 7),
                .toolCall(index: 1, arguments: #" "pen"}"#, decoded: 9),
                .finish("tool_calls", decoded: 10), .success,
            ]),
            .init(events: [.text("42, and a pen costs 3 EUR.", decoded: 8), .finish("stop", decoded: 8), .success]),
        ])
        let session = LanguageModelSession(model: model(backend), tools: [CalculatorTool(), LookupTool()])
        let response = try await session.respond(to: "6*7, and the price of a pen?")
        #expect(response.content == "42, and a pen costs 3 EUR.")

        let second = messages(try #require(backend.submissions.last))
        #expect(second.map { $0["role"] as? String } == ["user", "assistant", "tool", "tool"])
        let calls = try #require(second[1]["tool_calls"] as? [[String: Any]])
        #expect(calls.map { $0["id"] as? String } == ["c1", "c2"])
        #expect(second[1]["reasoning_content"] as? String == "Need both tools.")
        #expect(second[2]["tool_call_id"] as? String == "c1" && second[2]["content"] as? String == "42")
        #expect(second[3]["tool_call_id"] as? String == "c2" && second[3]["content"] as? String == "3 EUR")

        let kinds = session.transcript.map { entry -> String in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .reasoning: "reasoning"
            case .toolCalls(let calls): "calls:\(calls.count)"
            case .toolOutput: "output"
            case .response: "response"
            default: "other"
            }
        }
        // the framework adds instructions to carry the tool definitions
        #expect(kinds == ["instructions", "prompt", "reasoning", "calls:2", "output", "output", "response"])
    }

    @Test func toolsCombineWithAStructuredAnswer() async throws {
        let backend = ScriptedBackend([
            .init(events: [.toolCall(index: 0, id: "c1", name: "calculate", arguments: #"{"expression":"6*7"}"#, decoded: 5), .success]),
            .init(events: [.text(#"{"value": 42}"#, decoded: 5), .success]),
        ])
        let session = LanguageModelSession(model: model(backend), tools: [CalculatorTool()])
        let response = try await session.respond(to: "6*7?", generating: Total.self,
                                                 options: GenerationOptions(toolCallingMode: .required))
        #expect(response.content.value == 42)
        #expect(backend.submissions.count == 2)
        // a required call is asked once, then the model may answer
        #expect(backend.submissions.map { $0.json["tool_choice"] as? String } == ["required", "auto"])
        #expect(backend.submissions.allSatisfy { $0.json["response_format"] != nil && $0.json["tools"] != nil })
    }

    @Test func toolCallCutByTheTokenLimitIsAnError() async throws {
        let backend = ScriptedBackend([.init(events: [
            .toolCall(index: 0, id: "c1", name: "calculate", arguments: #"{"expres"#, decoded: 5),
            .finish("length", decoded: 5), .success,
        ])])
        do {
            _ = try await LanguageModelSession(model: model(backend), tools: [CalculatorTool()]).respond(to: "x")
            Issue.record("expected an error")
        } catch let LlamaLanguageModelError.incompleteToolCall(name, reason) {
            #expect(name == "calculate")
            #expect(reason.contains("token limit"))
        }
    }

    // MARK: Errors and cancellation

    @Test func errorAfterFragmentsFailsAndTheNextRequestStartsClean() async throws {
        let backend = ScriptedBackend([
            .init(events: [.text("partial", decoded: 90)], failure: contextOverflow(phase: "generation", prompt: 30, decoded: 98, size: 128)),
            .init(events: [.text("fine", decoded: 1), .success]),
        ])
        let session = LanguageModelSession(model: model(backend))
        do {
            _ = try await session.respond(to: "long")
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 128)
            #expect(info.tokenCount == 129)
            #expect(info.debugDescription.contains("generation"))
        }
        // the framework reverts the turn: the partial output is not history
        #expect(session.transcript.isEmpty)
        let next = try await session.respond(to: "short")
        #expect(next.content == "fine")
        #expect(!backend.submissions[1].text.contains("partial"))
        #expect(messages(backend.submissions[1]).count == 1)
    }

    @Test func promptOverflowIsContextSizeExceeded() async throws {
        let backend = ScriptedBackend([.init(failure: contextOverflow(phase: "prompt", prompt: 600, decoded: 0, size: 128))])
        do {
            _ = try await LanguageModelSession(model: model(backend)).respond(to: "x")
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.tokenCount == 600)
            #expect(info.debugDescription.contains("prompt"))
        }
    }

    @Test func runtimeErrorsStayTyped() async throws {
        let errors: [LlamaEngineError] = [
            .queueFull(waitingCapacity: 4), .admissionTimedOut(.seconds(1)), .unloaded(modelID),
            .modelUnavailable(modelID, reason: "removed"), .modelNotFound(modelID),
            .native(category: "load_failed", message: "bad file", details: Data("null".utf8)),
        ]
        for error in errors {
            let backend = ScriptedBackend([.init(submitError: error)])
            await #expect(throws: error) {
                _ = try await LanguageModelSession(model: model(backend)).respond(to: "x")
            }
        }
    }

    @Test func cancellingRespondReachesTheEngine() async throws {
        let backend = ScriptedBackend([.init(events: [.text("first", decoded: 1)], hangs: true),
                                       .init(events: [.text("again", decoded: 1), .success])])
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(backend, monitor: monitor))
        let task = Task { try await session.respond(to: "x") }
        try await until { monitor.state.phase == .generating }
        task.cancel()
        let outcome = try await within(.seconds(10)) { await task.result }
        guard case .failure(let error)? = outcome else {
            Issue.record("the response did not end after cancellation: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)
        #expect(backend.cancelledStreams == 1)
        try await until { monitor.state.phase == .idle }
        // the session accepts the next request, from the last complete turn
        #expect(try await session.respond(to: "y").content == "again")
        #expect(!backend.submissions[1].text.contains("first"))
    }

    /// Records what ending the iteration of a response stream does to the
    /// executor on this SDK (the cancellation of the consuming task).
    @Test func cancellingAStreamConsumer() async throws {
        let backend = ScriptedBackend([.init(events: [.text("first", decoded: 1)], hangs: true)])
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(backend, monitor: monitor))
        let task = Task {
            for try await _ in session.streamResponse(to: "x") {}
        }
        try await until { monitor.state.phase == .generating }
        task.cancel()
        let outcome = try await within(.seconds(5)) { await task.result }
        let engineCancelled = backend.cancelledStreams == 1
        print("P5 stream consumer cancelled: consumer ended=\(outcome != nil) engine cancelled=\(engineCancelled)")
        #expect(outcome != nil)
        #expect(engineCancelled)
    }

    // MARK: Capabilities

    @Test func capabilitiesComeFromQualification() throws {
        let backend = ScriptedBackend()
        let imported = model(backend, capabilities: nil)
        #expect(imported.capabilitySet == [.guidedGeneration])

        var entry = try LlamaModelCatalog.decode(Data(contentsOf: catalogFile)).models[0]
        entry.qualifiedCapabilities = [.toolCalling, .vision]
        backend.artifacts[modelID] = LlamaModelArtifact(id: modelID, weights: [URL(fileURLWithPath: "/m.gguf")],
                                                        projector: URL(fileURLWithPath: "/p.gguf"), catalogEntry: entry)
        #expect(model(backend, capabilities: nil).capabilitySet == [.guidedGeneration, .toolCalling, .vision])
        // vision needs a profile that loads the projector
        #expect(model(backend, capabilities: nil, profile: LlamaLoadProfile()).capabilitySet == [.guidedGeneration, .toolCalling])
        #expect(model(backend, capabilities: [.reasoning]).capabilitySet == [.reasoning])
    }

    @Test func undeclaredCapabilitiesAreRefusedBeforeSubmission() async throws {
        let backend = ScriptedBackend()
        let plain = model(backend, capabilities: [])
        do {
            _ = try await LanguageModelSession(model: plain, tools: [CalculatorTool()]).respond(to: "x")
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .toolCalling)
        }
        do {
            _ = try await LanguageModelSession(model: plain).respond(to: "x", generating: Total.self)
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .guidedGeneration)
        }
        #expect(backend.submissions.isEmpty)
    }

    @Test func imagesNeedAProjector() async throws {
        let backend = ScriptedBackend()
        backend.artifacts[modelID] = LlamaModelArtifact(id: modelID, weights: [URL(fileURLWithPath: "/m.gguf")])
        let image = try testImage(width: 2, height: 2)
        let session = LanguageModelSession(model: model(backend))
        do {
            _ = try await session.respond(to: Prompt {
                "What is it?"
                Attachment(image)
            })
            Issue.record("expected an error")
        } catch let LanguageModelError.unsupportedCapability(info) {
            #expect(info.capability == .vision)
            #expect(info.debugDescription.contains("projector"))
        }
        #expect(backend.submissions.isEmpty)
    }

    // MARK: Monitor

    @Test func monitorReportsProgressThenTheLastMeasure() async throws {
        let backend = ScriptedBackend([.init(events: [
            .progress(processed: 5, total: 10), .text("a", decoded: 1), .text("b", decoded: 2), .finish("stop", decoded: 2), .success,
        ])])
        let monitor = LlamaGenerationMonitor()
        #expect(monitor.state.context == nil) // unavailable, not zero
        var phases: [LlamaGenerationMonitor.State.Phase] = []
        var progress: [Double] = []
        let updates = monitor.updates()
        let reader = Task {
            for await state in updates {
                phases.append(state.phase)
                if let value = state.promptProgress { progress.append(value) }
                if phases.count > 1 && state.phase == .idle { break }
            }
            return (phases, progress)
        }
        _ = try await LanguageModelSession(model: model(backend, monitor: monitor)).respond(to: "x")
        let (seen, seenProgress) = await reader.value
        #expect(seen.first == .idle && seen.last == .idle)
        #expect(seen.contains(.generating))
        #expect(seenProgress.allSatisfy { (0...1).contains($0) })
        let final = monitor.state
        #expect(final.isContextLive == false)
        #expect(final.context?.occupiedTokens == 12)
        #expect(final.context?.contextSize == 4096)
    }
}

/// Polls a condition (at most `timeout`).
func until(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not reached in \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The result of `body`, or nil if it takes longer than `timeout` (the work
/// is then left running instead of being awaited).
func within<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
    let box = ResultBox<T>()
    let work = Task { box.set(try await body()) }
    let deadline = ContinuousClock.now + timeout
    while box.value == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    _ = work
    return box.value
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

private let catalogFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Catalog/models.json")

/// A small RGBA image with distinct width and height.
func testImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
