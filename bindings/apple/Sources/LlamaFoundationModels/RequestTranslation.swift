import Foundation
import FoundationModels
import LlamaEngine

/// An engine chat request built from one Foundation Models request.
struct EngineChatRequest {
    var body: JSONValue
    var attachments: [NativeAttachment]
    /// Name of the response schema, for error localization.
    var schemaName: String?
}

/// What the translation needs to know about the model.
struct ModelTraits {
    /// Capabilities the model declares.
    var capabilities: Set<LanguageModelCapabilities.Capability>
    /// Whether the chat template takes `reasoning_effort`; asked to the
    /// engine only when a reasoning level needs it.
    var supportsReasoningEffort: @Sendable () async throws -> Bool
}

/// Translates the complete transcript and the options of a request into an
/// engine chat request. Nothing of a previous request is kept: the engine
/// reuses a cached prefix only when the rendered prompt starts the same way.
struct RequestTranslation {
    static let schemaInstruction = "Respond with JSON that conforms to this JSON schema:"

    let request: LanguageModelExecutorGenerationRequest
    let traits: ModelTraits

    func build() async throws -> EngineChatRequest {
        var body: [(String, JSONValue)] = []
        var images = ImageCollector()
        let schema = try request.schema.map { try translatedSchema($0) }

        body.append(("messages", .array(try await messages(responseSchema: schema, images: &images))))

        let tools = try request.enabledToolDefinitions.map(tool)
        if let choice = try toolChoice() {
            body.append(("tools", .array(tools)))
            body.append(("tool_choice", .string(choice)))
        }
        if let schema {
            body.append(("response_format", [
                "type": "json_schema",
                "json_schema": ["name": .string(request.schema!.name), "schema": schema],
            ]))
        }
        body += try sampling()
        if let limit = request.generationOptions.maximumResponseTokens {
            guard limit > 0 else {
                throw LlamaLanguageModelError.unsupportedOption(
                    name: "maximumResponseTokens", reason: "\(limit) is not a positive number of tokens")
            }
            body.append(("max_tokens", .int(limit)))
        }
        body += try await reasoning()
        body += [
            ("stream", true),
            // a full context is an error, never a silent shift or a truncation
            ("fail_on_context_full", true),
            ("return_context", true),
            ("return_progress", true),
            // a schema the grammar would approximate is refused by the engine
            ("strict_json_schema", true),
        ]
        return EngineChatRequest(body: .object(body), attachments: images.attachments, schemaName: request.schema?.name)
    }

    // MARK: Transcript

    private struct AssistantDraft {
        var content: [String] = []
        var reasoning: [String] = []
        var toolCalls: [JSONValue] = []

        var isEmpty: Bool { content.isEmpty && reasoning.isEmpty && toolCalls.isEmpty }

        var message: JSONValue {
            var members: [(String, JSONValue)] = [("role", "assistant"), ("content", .string(content.joined(separator: "\n")))]
            if !reasoning.isEmpty {
                members.append(("reasoning_content", .string(reasoning.joined(separator: "\n"))))
            }
            if !toolCalls.isEmpty {
                members.append(("tool_calls", .array(toolCalls)))
            }
            return .object(members)
        }
    }

    private func messages(responseSchema: JSONValue?, images: inout ImageCollector) async throws -> [JSONValue] {
        var messages: [JSONValue] = []
        var assistant = AssistantDraft()
        func flush() {
            if !assistant.isEmpty {
                messages.append(assistant.message)
                assistant = AssistantDraft()
            }
        }
        let entries = Array(request.transcript)
        let lastPrompt = entries.lastIndex { if case .prompt = $0 { true } else { false } }

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .instructions(let instructions):
                flush()
                // the framework adds empty instructions to carry the tool definitions
                let content = try await content(instructions.segments, entry, &images)
                if content != .string("") {
                    messages.append(["role": "system", "content": content])
                }
            case .prompt(let prompt):
                flush()
                var content = try await self.content(prompt.segments, entry, &images)
                if let schemaText = try schemaText(for: prompt, isLast: index == lastPrompt, responseSchema: responseSchema) {
                    content = appending(schemaText, to: content)
                }
                messages.append(["role": "user", "content": content])
            case .response(let response):
                if !assistant.toolCalls.isEmpty {
                    flush()
                }
                assistant.content.append(try text(response.segments, entry))
            case .reasoning(let reasoning):
                if !assistant.content.isEmpty || !assistant.toolCalls.isEmpty {
                    flush()
                }
                assistant.reasoning.append(try text(reasoning.segments, entry))
            case .toolCalls(let calls):
                for call in calls {
                    assistant.toolCalls.append([
                        "id": .string(call.id),
                        "type": "function",
                        "function": ["name": .string(call.toolName), "arguments": .string(call.arguments.jsonString)],
                    ])
                }
            case .toolOutput(let output):
                flush()
                messages.append([
                    "role": "tool",
                    "tool_call_id": .string(output.id),
                    "name": .string(output.toolName),
                    "content": try await content(output.segments, entry, &images),
                ])
            @unknown default:
                throw LanguageModelError.unsupportedTranscriptContent(.init(
                    unsupportedContent: [entry], debugDescription: "unknown transcript entry"))
            }
        }
        flush()
        return messages
    }

    /// Text and images in their order: a string when there is no image.
    private func content(_ segments: [Transcript.Segment], _ entry: Transcript.Entry,
                         _ images: inout ImageCollector) async throws -> JSONValue {
        var parts: [JSONValue] = []
        var texts: [String] = []
        var hasImage = false
        for segment in segments {
            switch segment {
            case .text(let text):
                texts.append(text.content)
                parts.append(["type": "text", "text": .string(text.content)])
            case .structure(let structure):
                texts.append(structure.content.jsonString)
                parts.append(["type": "text", "text": .string(structure.content.jsonString)])
            case .attachment(let attachment):
                guard case .image(let image) = attachment.content else {
                    throw LanguageModelError.unsupportedTranscriptContent(.init(
                        unsupportedContent: [entry], debugDescription: "only image attachments are supported"))
                }
                hasImage = true
                let name = try await images.add(image)
                parts.append(["type": "image_url", "image_url": ["url": .string("attachment:\(name)")]])
            @unknown default:
                throw LanguageModelError.unsupportedTranscriptContent(.init(
                    unsupportedContent: [entry], debugDescription: "unknown segment"))
            }
        }
        return hasImage ? .array(parts) : .string(texts.joined(separator: "\n"))
    }

    /// Text of an entry the model wrote: images there have no translation.
    private func text(_ segments: [Transcript.Segment], _ entry: Transcript.Entry) throws -> String {
        try segments.map { segment -> String in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            default:
                throw LanguageModelError.unsupportedTranscriptContent(.init(
                    unsupportedContent: [entry], debugDescription: "a model output with an attachment has no translation"))
            }
        }.joined(separator: "\n")
    }

    private func appending(_ text: String, to content: JSONValue) -> JSONValue {
        switch content {
        case .string(let existing):
            return .string(existing.isEmpty ? text : existing + "\n\n" + text)
        case .array(let parts):
            return .array(parts + [["type": "text", "text": .string(text)]])
        default:
            return content
        }
    }

    // MARK: Schema

    private func translatedSchema(_ schema: GenerationSchema) throws -> JSONValue {
        do {
            return try SchemaTranslation.translate(schema)
        } catch let refusal as SchemaTranslation.Refusal {
            throw refusal.languageModelError
        }
    }

    /// The schema is written in a prompt that carries a response format (the
    /// framework sets it when `includeSchemaInPrompt` is true), so that every
    /// request renders the history the same way. The current request follows
    /// its own `includeSchemaInPrompt`.
    private func schemaText(for prompt: Transcript.Prompt, isLast: Bool, responseSchema: JSONValue?) throws -> String? {
        var schema: JSONValue?
        if isLast, let include = request.contextOptions.includeSchemaInPrompt {
            schema = include ? (try prompt.responseFormat.map(formatSchema) ?? responseSchema) : nil
        } else {
            schema = try prompt.responseFormat.map(formatSchema)
        }
        return schema.map { "\(Self.schemaInstruction)\n\($0.serialized)" }
    }

    private func formatSchema(_ format: Transcript.ResponseFormat) throws -> JSONValue {
        switch format.kind {
        case .schema(let schema):
            return try translatedSchema(schema)
        @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(.init(
                unsupportedContent: [], debugDescription: "unknown response format \(format.name)"))
        }
    }

    // MARK: Tools

    private func tool(_ definition: Transcript.ToolDefinition) throws -> JSONValue {
        let parameters: JSONValue
        do {
            parameters = try SchemaTranslation.translate(definition.parameters)
        } catch let refusal as SchemaTranslation.Refusal {
            throw LanguageModelError.unsupportedGenerationGuide(.init(
                schemaName: definition.name, debugDescription: "parameters of tool \(definition.name): \(refusal.reason)"))
        }
        return [
            "type": "function",
            "function": ["name": .string(definition.name), "description": .string(definition.description),
                         "parameters": parameters],
        ]
    }

    /// `allowed` → `auto`, `disallowed` → `none`. `required` asks for at
    /// least one tool call in the answer to the last prompt: once the
    /// transcript holds calls after it, the model may answer (`auto`), else
    /// the session would call tools forever (the framework repeats the mode
    /// in the requests that follow the tool outputs).
    func toolChoice() throws -> String? {
        let mode = request.generationOptions.toolCallingMode?.kind ?? .allowed
        guard !request.enabledToolDefinitions.isEmpty else {
            if mode == .required {
                throw LanguageModelError.unsupported(.toolCalling, "a tool call is required, but no tool is enabled")
            }
            return nil
        }
        switch mode {
        case .disallowed:
            return "none"
        case .required:
            let entries = Array(request.transcript)
            let lastPrompt = entries.lastIndex { if case .prompt = $0 { true } else { false } } ?? -1
            let called = entries[(lastPrompt + 1)...].contains { if case .toolCalls = $0 { true } else { false } }
            return called ? "auto" : "required"
        default:
            return "auto"
        }
    }

    // MARK: Options

    /// Explicit sampler chains: the engine's default chain (penalties, min-p,
    /// ...) is not applied to a sampling mode chosen by the caller.
    func sampling() throws -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        let temperature = request.generationOptions.temperature
        if let temperature {
            guard temperature.isFinite, temperature >= 0 else {
                throw LlamaLanguageModelError.unsupportedOption(name: "temperature", reason: "\(temperature) is not a non-negative number")
            }
        }
        func seed(_ value: UInt64?) throws {
            guard let value else { return }
            // the engine seed is 32 bits wide and 0xFFFFFFFF means "random"
            guard value < 0xFFFF_FFFF else {
                throw LlamaLanguageModelError.unsupportedOption(
                    name: "seed", reason: "\(value) does not fit the engine's 32-bit seed (at most 4294967294)")
            }
            out.append(("seed", .int(Int(value))))
        }
        switch request.generationOptions.samplingMode?.kind {
        case nil:
            if let temperature {
                out.append(("temperature", .double(temperature)))
            }
        case .greedy?:
            // argmax: the temperature has no effect
            out += [("samplers", ["top_k"]), ("top_k", 1)]
        case let .randomTopK(k, value)?:
            guard k >= 1 else {
                throw LlamaLanguageModelError.unsupportedOption(name: "sampling", reason: "top-k \(k) is not positive")
            }
            out += [("samplers", ["top_k", "temperature"]), ("top_k", .int(k))]
            if let temperature { out.append(("temperature", .double(temperature))) }
            try seed(value)
        case let .randomProbabilityThreshold(p, value)?:
            guard p > 0, p <= 1 else {
                throw LlamaLanguageModelError.unsupportedOption(name: "sampling", reason: "probability threshold \(p) is not in (0, 1]")
            }
            out += [("samplers", ["top_p", "temperature"]), ("top_p", .double(p))]
            if let temperature { out.append(("temperature", .double(temperature))) }
            try seed(value)
        @unknown default:
            throw LlamaLanguageModelError.unsupportedOption(name: "sampling", reason: "unknown sampling mode")
        }
        return out
    }

    /// Reasoning: `nil` keeps the template's default. A model that does not
    /// declare reasoning never thinks. `custom("none")` turns reasoning off;
    /// the other levels need a template that takes `reasoning_effort`
    /// (light → low, moderate → medium, deep → high, custom → as given).
    func reasoning() async throws -> [(String, JSONValue)] {
        guard traits.capabilities.contains(.reasoning) else {
            return [("chat_template_kwargs", ["enable_thinking": false])]
        }
        let effort: String
        switch request.contextOptions.reasoningLevel {
        case nil:
            return []
        case .light?: effort = "low"
        case .moderate?: effort = "medium"
        case .deep?: effort = "high"
        case .custom(let value)?:
            if value == "none" {
                return [("chat_template_kwargs", ["enable_thinking": false])]
            }
            effort = value
        @unknown default:
            throw LanguageModelError.unsupported(.reasoning, "unknown reasoning level")
        }
        guard try await traits.supportsReasoningEffort() else {
            throw LanguageModelError.unsupported(.reasoning, "the reasoning level \(String(describing: request.contextOptions.reasoningLevel!)) "
                + "has no translation: the chat template of this model does not take reasoning_effort "
                + "(use nil for its default, or custom(\"none\") to turn reasoning off)")
        }
        return [("reasoning_effort", .string(effort))]
    }
}

/// Owned image bytes referenced as `attachment:image-N`.
struct ImageCollector {
    private(set) var attachments: [NativeAttachment] = []

    mutating func add(_ image: Transcript.ImageAttachment) async throws -> String {
        let name = "image-\(attachments.count + 1)"
        let bytes: Data
        do {
            bytes = try await ImageEncoding.png(image)
        } catch let failure as ImageEncoding.Failure {
            throw LanguageModelError.unsupported(.vision, "the image cannot be converted: \(failure.reason)")
        }
        attachments.append(NativeAttachment(name: name, bytes: bytes))
        return name
    }
}
