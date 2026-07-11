public import Foundation
public import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ key: some CodingKey) {
        self.stringValue = key.stringValue
        self.intValue = key.intValue
    }
}

#if canImport(CoreImage)
import CoreImage
import UniformTypeIdentifiers
#endif

@available(iOS 27.0, macOS 27.0, *)
package enum LlamaOpenAICompatibleGenerationRequestBuilder {
    package static func request(
        from request: LanguageModelExecutorGenerationRequest,
        modelName: String,
        extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
        unsupportedBy owner: Any.Type,
        invalidRequest: (String) -> any Error
    ) throws -> LlamaOpenAICompatibleChatCompletionRequest {
        try LlamaOpenAICompatibleChatCompletionRequest(
            model: modelName,
            messages: LlamaOpenAICompatibleChatTranscriptConverter.convertedTranscript(
                request.transcript,
                unsupportedBy: owner
            ),
            temperature: request.generationOptions.temperature,
            topP: request.generationOptions.samplingMode.map {
                try LlamaOpenAICompatibleRequestOptions.topP($0, invalidRequest: invalidRequest)
            },
            maxCompletionTokens: request.generationOptions.maximumResponseTokens,
            tools: LlamaOpenAICompatibleRequestOptions.nonEmpty(
                request.enabledToolDefinitions.map { tool in
                    LlamaOpenAICompatibleChatTool(
                        function: LlamaOpenAICompatibleChatTool.Function(
                            name: tool.name,
                            description: tool.description,
                            parameters: tool.parameters
                        )
                    )
                }
            ),
            toolChoice: LlamaOpenAICompatibleRequestOptions.toolChoiceMode(
                for: request.enabledToolDefinitions,
                mode: request.generationOptions.toolCallingMode
            ).map(LlamaOpenAICompatibleChatCompletionRequest.ToolChoice.init(mode:)),
            responseFormat: request.schema.map { schema in
                LlamaOpenAICompatibleChatResponseFormat(
                    jsonSchema: LlamaOpenAICompatibleChatResponseFormat.JSONSchemaWrapper(
                        name: schema.llamaOpenAICompatibleTitle,
                        schema: schema
                    )
                )
            },
            extraBody: extraBody
        )
    }

    package static func requestJSON(
        from request: LanguageModelExecutorGenerationRequest,
        modelName: String,
        extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:],
        unsupportedBy owner: Any.Type,
        invalidRequest: (String) -> any Error
    ) throws -> String {
        let request = try self.request(
            from: request,
            modelName: modelName,
            extraBody: extraBody,
            unsupportedBy: owner,
            invalidRequest: invalidRequest
        )
        let data = try JSONEncoder().encode(request)
        return String(decoding: data, as: UTF8.self)
    }
}

@available(iOS 27.0, macOS 27.0, *)
package enum LlamaOpenAICompatibleGenerationStreamProcessor {
    private struct ToolCallState {
        var id = ""
        var name = ""
        var pendingArguments = ""
        var announced = false
    }

    package static func processJSONStrings<JSONSequence: AsyncSequence>(
        _ jsonStrings: JSONSequence,
        into channel: LanguageModelExecutorGenerationChannel,
        invalidStreamData: @escaping @Sendable (_ jsonString: String) -> any Error,
        apiError: @escaping @Sendable (_ error: LlamaOpenAICompatibleErrorResponse.APIError) -> any Error
    ) async throws where JSONSequence.Element == String, JSONSequence: Sendable, JSONSequence.AsyncIterator: Sendable {
        var toolCalls: [Int: ToolCallState] = [:]
        var metadata = LlamaOpenAICompatibleMetadata()
        let responseEntryID = UUID().uuidString
        let reasoningEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString
        let decoder = JSONDecoder()

        for try await jsonString in jsonStrings {
            try Task.checkCancellation()

            guard let data = jsonString.data(using: .utf8) else {
                throw invalidStreamData(jsonString)
            }

            if let response = try? decoder.decode(LlamaOpenAICompatibleErrorResponse.self, from: data) {
                throw apiError(response.error)
            }

            let chunk: LlamaOpenAICompatibleChatCompletionChunk<LlamaOpenAICompatibleTelemetryFields>
            do {
                chunk = try decoder.decode(
                    LlamaOpenAICompatibleChatCompletionChunk<LlamaOpenAICompatibleTelemetryFields>.self,
                    from: data
                )
            } catch {
                throw invalidStreamData(jsonString)
            }

            await process(
                chunk,
                into: channel,
                responseEntryID: responseEntryID,
                reasoningEntryID: reasoningEntryID,
                toolCallsEntryID: toolCallsEntryID,
                toolCalls: &toolCalls,
                metadata: &metadata
            )
        }
    }

    package static func process<ChunkSequence: AsyncSequence>(
        _ chunks: ChunkSequence,
        into channel: LanguageModelExecutorGenerationChannel
    ) async throws where ChunkSequence.Element: LlamaOpenAICompatibleChatCompletionChunkEvent {
        var toolCalls: [Int: ToolCallState] = [:]
        var metadata = LlamaOpenAICompatibleMetadata()
        let responseEntryID = UUID().uuidString
        let reasoningEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString

        for try await chunk in chunks {
            try Task.checkCancellation()
            await process(
                chunk,
                into: channel,
                responseEntryID: responseEntryID,
                reasoningEntryID: reasoningEntryID,
                toolCallsEntryID: toolCallsEntryID,
                toolCalls: &toolCalls,
                metadata: &metadata
            )
        }
    }

    private static func process(
        _ chunk: some LlamaOpenAICompatibleChatCompletionChunkEvent,
        into channel: LanguageModelExecutorGenerationChannel,
        responseEntryID: String,
        reasoningEntryID: String,
        toolCallsEntryID: String,
        toolCalls: inout [Int: ToolCallState],
        metadata: inout LlamaOpenAICompatibleMetadata
    ) async {
        if let delta = chunk.choices.first?.delta {
            if let reasoning = delta.reasoningContent {
                await channel.send(
                    .reasoning(
                        entryID: reasoningEntryID,
                        action: .appendText(reasoning, tokenCount: 1)
                    )
                )
            }

            if let text = delta.content {
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .appendText(text, tokenCount: 1)
                    )
                )
            }

            for toolCallDelta in delta.toolCalls ?? [] {
                var state = toolCalls[toolCallDelta.index] ?? ToolCallState()
                state.id += toolCallDelta.id ?? ""
                state.name += toolCallDelta.function?.name ?? ""
                let arguments = toolCallDelta.function?.arguments ?? ""

                guard !state.id.isEmpty, !state.name.isEmpty else {
                    state.pendingArguments += arguments
                    toolCalls[toolCallDelta.index] = state
                    continue
                }

                let wasAnnounced = state.announced
                let emittedArguments: String
                if wasAnnounced {
                    emittedArguments = arguments
                } else {
                    emittedArguments = state.pendingArguments + arguments
                    state.pendingArguments = ""
                    state.announced = true
                }
                toolCalls[toolCallDelta.index] = state

                guard !wasAnnounced || !emittedArguments.isEmpty else { continue }
                await channel.send(
                    .toolCalls(
                        entryID: toolCallsEntryID,
                        action: .toolCall(
                            id: state.id,
                            name: state.name,
                            action: .appendArguments(
                                emittedArguments,
                                tokenCount: emittedArguments.isEmpty ? 0 : 1
                            )
                        )
                    )
                )
            }
        }

        if let chunkMetadata = chunk.metadata, !chunkMetadata.values.isEmpty {
            metadata.values.merge(chunkMetadata.values, uniquingKeysWith: { _, new in new })
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    action: .updateMetadata(metadata.values)
                )
            )
        }

        if let usage = chunk.usage {
            await channel.sendLlamaOpenAICompatibleUsage(usage, responseEntryID: responseEntryID)
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleChatCompletionRequest: Encodable {
    struct ToolChoice: Encodable {
        let mode: LlamaOpenAICompatibleToolChoiceMode

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(mode)
        }
    }

    var model: String
    var messages: [LlamaOpenAICompatibleChatMessage]
    var temperature: Double?
    var topP: Double?
    var maxCompletionTokens: Int?
    var tools: [LlamaOpenAICompatibleChatTool]?
    var toolChoice: ToolChoice?
    var responseFormat: LlamaOpenAICompatibleChatResponseFormat?
    var stream = true
    var streamOptions = StreamOptions(includeUsage: true)
    var extraBody: [String: LlamaOpenAICompatibleJSONValue] = [:]

    struct StreamOptions: Encodable {
        var includeUsage: Bool

        private enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    private static let reservedExtraBodyKeys: Set<String> = [
        "model",
        "messages",
        "temperature",
        "top_p",
        "max_completion_tokens",
        "max_tokens",
        "n_predict",
        "tools",
        "tool_choice",
        "response_format",
        "stream",
        "stream_options",
    ]

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case maxCompletionTokens = "max_completion_tokens"
        case tools
        case responseFormat = "response_format"
        case stream
        case streamOptions = "stream_options"
        case toolChoice = "tool_choice"
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LlamaOpenAICompatibleDynamicCodingKey.self)
        for (key, value) in extraBody where !Self.reservedExtraBodyKeys.contains(key) {
            try container.encode(value, forKey: LlamaOpenAICompatibleDynamicCodingKey(stringValue: key))
        }

        try container.encode(model, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.model))
        try container.encode(messages, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.messages))
        try container.encodeIfPresent(temperature, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.temperature))
        try container.encodeIfPresent(topP, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.topP))
        try container.encodeIfPresent(maxCompletionTokens, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.maxCompletionTokens))
        try container.encodeIfPresent(tools, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.tools))
        try container.encodeIfPresent(toolChoice, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.toolChoice))
        try container.encodeIfPresent(responseFormat, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.responseFormat))
        try container.encode(stream, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.stream))
        try container.encode(streamOptions, forKey: LlamaOpenAICompatibleDynamicCodingKey(CodingKeys.streamOptions))
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleChatMessage: Encodable {
    var role: Role
    var content: [LlamaOpenAICompatibleChatMessageContent]
    var toolCalls: [LlamaOpenAICompatibleChatToolCall]?
    var toolCallID: String?
    var reasoningContent: String?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }

    enum Role: String, Encodable {
        case system
        case user
        case assistant
        case tool
    }

    init(
        role: Role,
        content: [LlamaOpenAICompatibleChatMessageContent] = [],
        toolCalls: [LlamaOpenAICompatibleChatToolCall]? = nil,
        toolCallID: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoningContent = reasoningContent
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        let hasToolCalls = toolCalls?.isEmpty == false
        let compactText = content.count == 1 ? content.first?.text : nil
        if let compactText {
            try container.encode(compactText, forKey: .content)
        } else if !hasToolCalls {
            if content.isEmpty {
                try container.encode("", forKey: .content)
            } else {
                try container.encode(content, forKey: .content)
            }
        }

        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleChatMessageContent: Codable {
    var type: ContentType
    var text: String?
    var imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    enum ContentType: String, Codable {
        case text
        case imageURL = "image_url"
    }

    struct ImageURL: Codable {
        var url: URL
        var detail: String? = "auto"
    }

    init(text: String) {
        self.type = .text
        self.text = text
        self.imageURL = nil
    }

    init(imageURL: ImageURL) {
        self.type = .imageURL
        self.text = nil
        self.imageURL = imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleChatTool: Encodable {
    var type = "function"
    var function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let strict = true
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleChatToolCall: Codable {
    var id: String
    var type = "function"
    var function: FunctionCall

    struct FunctionCall: Codable {
        var name: String
        var arguments: String
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct LlamaOpenAICompatibleChatResponseFormat: Encodable {
    var type = "json_schema"
    var jsonSchema: JSONSchemaWrapper

    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    struct JSONSchemaWrapper: Encodable {
        var name: String
        var description: String?
        var schema: GenerationSchema
        var strict = true
    }
}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleChatCompletionChunk<ProviderMetadata>: Decodable, Sendable
where ProviderMetadata: LlamaOpenAICompatibleChatCompletionMetadataFields {
    let id: String?
    let model: String?
    package let choices: [LlamaOpenAICompatibleChatCompletionChoice]
    package let usage: LlamaOpenAICompatibleUsage?
    let providerMetadata: ProviderMetadata

    package var metadata: LlamaOpenAICompatibleMetadata? { providerMetadata.metadata }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case choices
        case usage
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        choices = try container.decodeIfPresent([LlamaOpenAICompatibleChatCompletionChoice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(LlamaOpenAICompatibleUsage.self, forKey: .usage)
        providerMetadata = try ProviderMetadata(from: decoder)
    }
}

@available(iOS 27.0, macOS 27.0, *)
package protocol LlamaOpenAICompatibleChatCompletionMetadataFields: Decodable, Sendable {
    var metadata: LlamaOpenAICompatibleMetadata? { get }
}

@available(iOS 27.0, macOS 27.0, *)
package protocol LlamaOpenAICompatibleChatCompletionChunkEvent: Sendable {
    var choices: [LlamaOpenAICompatibleChatCompletionChoice] { get }
    var usage: LlamaOpenAICompatibleUsage? { get }
    var metadata: LlamaOpenAICompatibleMetadata? { get }
}

@available(iOS 27.0, macOS 27.0, *)
extension LlamaOpenAICompatibleTelemetryFields: LlamaOpenAICompatibleChatCompletionMetadataFields {}

@available(iOS 27.0, macOS 27.0, *)
extension LlamaOpenAICompatibleChatCompletionChunk: LlamaOpenAICompatibleChatCompletionChunkEvent {}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleChatCompletionChoice: Decodable, Sendable {
    let delta: LlamaOpenAICompatibleChatCompletionDelta
}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleChatCompletionDelta: Decodable, Sendable {
    var role: String?
    var content: String?
    var reasoningContent: String?
    var toolCalls: [LlamaOpenAICompatibleChatToolCallDelta]?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleChatToolCallDelta: Decodable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let function: FunctionCallDelta?

    struct FunctionCallDelta: Decodable, Sendable {
        let name: String?
        let arguments: String?
    }
}

@available(iOS 27.0, macOS 27.0, *)
package struct LlamaOpenAICompatibleUsage: Decodable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let inputTokensDetails: InputTokensDetails?
    let outputTokensDetails: OutputTokensDetails?

    var promptTokens: Int { inputTokens }
    var completionTokens: Int { outputTokens }
    var cachedTokens: Int { inputTokensDetails?.cachedTokens ?? 0 }
    var reasoningTokens: Int { outputTokensDetails?.reasoningTokens ?? 0 }

    struct InputTokensDetails: Decodable, Sendable {
        let cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct OutputTokensDetails: Decodable, Sendable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokensDetails = "output_tokens_details"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens =
            try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            ?? container.decode(Int.self, forKey: .promptTokens)
        outputTokens =
            try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            ?? container.decode(Int.self, forKey: .completionTokens)
        inputTokensDetails =
            try container.decodeIfPresent(InputTokensDetails.self, forKey: .inputTokensDetails)
            ?? container.decodeIfPresent(InputTokensDetails.self, forKey: .promptTokensDetails)
        outputTokensDetails =
            try container.decodeIfPresent(OutputTokensDetails.self, forKey: .outputTokensDetails)
            ?? container.decodeIfPresent(OutputTokensDetails.self, forKey: .completionTokensDetails)
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum LlamaOpenAICompatibleToolChoiceMode: String, Encodable, Sendable {
    case auto
    case required
    case none
}

@available(iOS 27.0, macOS 27.0, *)
enum LlamaOpenAICompatibleRequestOptions {
    static func nonEmpty<T>(_ values: [T]) -> [T]? {
        values.isEmpty ? nil : values
    }

    static func toolChoiceMode<Tools: Collection>(
        for tools: Tools,
        mode: GenerationOptions.ToolCallingMode?
    ) -> LlamaOpenAICompatibleToolChoiceMode? {
        guard !tools.isEmpty else { return nil }

        switch mode {
        case .allowed, .none:
            return .auto
        case .required:
            return .required
        case .disallowed:
            return LlamaOpenAICompatibleToolChoiceMode.none
        default:
            return .auto
        }
    }

    static func topP(
        _ sampling: GenerationOptions.SamplingMode,
        invalidRequest: (String) -> any Error
    ) throws -> Double {
        switch sampling.kind {
        case .greedy:
            return 0
        case .randomTopK:
            throw invalidRequest("Top K sampling is not supported")
        case .randomProbabilityThreshold(let threshold, let seed):
            guard seed == nil else {
                throw invalidRequest("Setting a random seed is not supported")
            }
            return threshold
        @unknown default:
            throw invalidRequest("Unknown sampling mode \(sampling.kind) is not supported")
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum LlamaOpenAICompatibleChatTranscriptConverter {
    static func convertedTranscript(
        _ entries: some Collection<Transcript.Entry>,
        unsupportedBy owner: Any.Type
    ) throws -> [LlamaOpenAICompatibleChatMessage] {
        var messages: [LlamaOpenAICompatibleChatMessage] = []
        var pendingReasoning: String?

        func consumePendingReasoning() -> String? {
            defer { pendingReasoning = nil }
            return pendingReasoning
        }

        for entry in entries {
            switch entry {
            case .instructions(let instructions):
                let content = try instructions.segments.flatMap { try convertedSegment($0, in: entry, unsupportedBy: owner) }
                if !content.isEmpty {
                    messages.append(LlamaOpenAICompatibleChatMessage(role: .system, content: content))
                }

            case .prompt(let prompt):
                if let reasoning = consumePendingReasoning() {
                    messages.append(LlamaOpenAICompatibleChatMessage(role: .assistant, reasoningContent: reasoning))
                }
                messages.append(
                    LlamaOpenAICompatibleChatMessage(
                        role: .user,
                        content: try prompt.segments.flatMap { try convertedSegment($0, in: entry, unsupportedBy: owner) }
                    )
                )

            case .toolCalls(let toolCalls):
                let calls = toolCalls.map { call in
                    LlamaOpenAICompatibleChatToolCall(
                        id: call.id,
                        function: LlamaOpenAICompatibleChatToolCall.FunctionCall(
                            name: call.toolName,
                            arguments: call.arguments.jsonString
                        )
                    )
                }
                let reasoning = consumePendingReasoning()
                if !calls.isEmpty || reasoning != nil {
                    messages.append(
                        LlamaOpenAICompatibleChatMessage(
                            role: .assistant,
                            toolCalls: calls,
                            reasoningContent: reasoning
                        )
                    )
                }

            case .toolOutput(let toolOutput):
                messages.append(
                    LlamaOpenAICompatibleChatMessage(
                        role: .tool,
                        content: try toolOutput.segments.flatMap { try convertedSegment($0, in: entry, unsupportedBy: owner) },
                        toolCallID: toolOutput.id
                    )
                )

            case .response(let response):
                let content = try response.segments.flatMap { try convertedSegment($0, in: entry, unsupportedBy: owner) }
                let reasoning = consumePendingReasoning()
                if !content.isEmpty || reasoning != nil {
                    messages.append(
                        LlamaOpenAICompatibleChatMessage(
                            role: .assistant,
                            content: content,
                            reasoningContent: reasoning
                        )
                    )
                }

            case .reasoning(let reasoning):
                let text = reasoning.segments.compactMap { segment -> String? in
                    if case .text(let textSegment) = segment { return textSegment.content }
                    return nil
                }.joined()
                pendingReasoning = (pendingReasoning ?? "") + text

            @unknown default:
                continue
            }
        }

        if let reasoning = consumePendingReasoning() {
            messages.append(LlamaOpenAICompatibleChatMessage(role: .assistant, reasoningContent: reasoning))
        }

        return messages
    }

    private static func convertedSegment(
        _ segment: Transcript.Segment,
        in entry: Transcript.Entry,
        unsupportedBy owner: Any.Type
    ) throws -> [LlamaOpenAICompatibleChatMessageContent] {
        switch segment {
        case .text(let text):
            return [LlamaOpenAICompatibleChatMessageContent(text: text.content)]
        case .structure(let structure):
            return [LlamaOpenAICompatibleChatMessageContent(text: structure.content.jsonString)]
        case .attachment:
            let dataURL = try imageDataURL(from: segment, in: entry, unsupportedBy: owner)
            return [
                LlamaOpenAICompatibleChatMessageContent(
                    imageURL: LlamaOpenAICompatibleChatMessageContent.ImageURL(url: dataURL)
                )
            ]
        case .custom:
            throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                    unsupportedContent: [entry],
                    debugDescription: "Custom segments are not supported by \(owner)"
                )
            )
        @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                    unsupportedContent: [entry],
                    debugDescription: "Unknown segment type not supported by \(owner)"
                )
            )
        }
    }

    private static func imageDataURL(
        from segment: Transcript.Segment,
        in entry: Transcript.Entry,
        unsupportedBy owner: Any.Type
    ) throws -> URL {
        guard case .attachment(let attachment) = segment else {
            throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                    unsupportedContent: [entry],
                    debugDescription: "Segment is not an image attachment."
                )
            )
        }

        switch attachment.content {
        case .image(let image):
            #if canImport(CoreImage)
            let base64String = image.cgImage.llamaOpenAICompatibleJPEGData().base64EncodedString()
            return URL(string: "data:image/jpeg;base64,\(base64String)")!
            #else
            if image.url.scheme == "data" {
                return image.url
            }
            let data = try Data(contentsOf: image.url)
            let base64String = data.base64EncodedString()
            return URL(string: "data:image/jpeg;base64,\(base64String)")!
            #endif
        @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                    unsupportedContent: [entry],
                    debugDescription: "Attachment type not supported by \(owner)."
                )
            )
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension LanguageModelExecutorGenerationChannel {
    func sendLlamaOpenAICompatibleUsage(
        _ usage: LlamaOpenAICompatibleUsage,
        responseEntryID: String
    ) async {
        await send(
            .response(
                entryID: responseEntryID,
                action: .updateUsage(
                    input: .init(
                        totalTokenCount: usage.promptTokens,
                        cachedTokenCount: usage.cachedTokens
                    ),
                    output: .init(
                        totalTokenCount: usage.completionTokens,
                        reasoningTokenCount: usage.reasoningTokens
                    )
                )
            )
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension GenerationSchema {
    var llamaOpenAICompatibleTitle: String {
        let schema = try! JSONEncoder().encode(self)
        let dictionary =
            try! JSONSerialization.jsonObject(
                with: schema,
                options: []
            ) as! [String: Any]
        if let title = dictionary["title"] as? String {
            return title
        }
        if let type = dictionary["type"] as? String {
            return type
        }
        return "Response"
    }
}

#if canImport(CoreImage)
@available(iOS 27.0, macOS 27.0, *)
private extension CGImage {
    func llamaOpenAICompatibleJPEGData() -> Data {
        let imageData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            imageData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, self, nil)
        CGImageDestinationFinalize(destination)
        return Data(referencing: imageData)
    }
}
#endif
