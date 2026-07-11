import Foundation
import FoundationModels
import Testing
@testable import LlamaOpenAICompatible

struct GenerationRequestTests {
    @Test func transcriptConvertsToChatMessages() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let messages = try LlamaOpenAICompatibleChatTranscriptConverter.convertedTranscript(
            [
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: "Be concise."))],
                        toolDefinitions: []
                    )
                ),
                .prompt(
                    Transcript.Prompt(
                        segments: [.text(Transcript.TextSegment(content: "Hello"))]
                    )
                ),
                .response(
                    Transcript.Response(
                        segments: [.text(Transcript.TextSegment(content: "Hi"))]
                    )
                ),
                .reasoning(
                    Transcript.Reasoning(
                        segments: [.text(Transcript.TextSegment(content: "Think"))]
                    )
                ),
                .toolCalls(
                    Transcript.ToolCalls([
                        Transcript.ToolCall(
                            id: "call_weather",
                            toolName: "get_weather",
                            arguments: try GeneratedContent(json: #"{"location":"Paris"}"#)
                        )
                    ])
                ),
                .toolOutput(
                    Transcript.ToolOutput(
                        id: "call_weather",
                        toolName: "get_weather",
                        segments: [.text(Transcript.TextSegment(content: "Sunny"))]
                    )
                ),
            ],
            unsupportedBy: Self.self
        )

        let encoded = try encodedJSONArray(messages)

        #expect(encoded[0]["role"] as? String == "system")
        #expect(encoded[0]["content"] as? String == "Be concise.")
        #expect(encoded[1]["role"] as? String == "user")
        #expect(encoded[1]["content"] as? String == "Hello")
        #expect(encoded[2]["role"] as? String == "assistant")
        #expect(encoded[2]["content"] as? String == "Hi")
        #expect(encoded[3]["role"] as? String == "assistant")
        #expect(encoded[3]["reasoning_content"] as? String == "Think")
        #expect((encoded[3]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_weather")
        #expect(encoded[4]["role"] as? String == "tool")
        #expect(encoded[4]["tool_call_id"] as? String == "call_weather")
        #expect(encoded[4]["content"] as? String == "Sunny")
    }

    @Test func extraBodyCannotOverrideReservedGenerationFields() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let request = LlamaOpenAICompatibleChatCompletionRequest(
            model: "model-from-adapter",
            messages: [
                LlamaOpenAICompatibleChatMessage(
                    role: .user,
                    content: [LlamaOpenAICompatibleChatMessageContent(text: "Hello")]
                )
            ],
            temperature: nil,
            topP: nil,
            maxCompletionTokens: 32,
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            extraBody: [
                "model": .string("model-from-extra-body"),
                "messages": .string("not-a-message-list"),
                "max_tokens": .number(999),
                "stream": .bool(false),
                "timings_per_token": .bool(true),
            ]
        )

        let body = try encodedObject(request)

        #expect(body["model"] as? String == "model-from-adapter")
        #expect(body["messages"] is [[String: Any]])
        #expect(body["max_completion_tokens"] as? Int == 32)
        #expect(body["max_tokens"] == nil)
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(body["timings_per_token"] as? Bool == true)
    }

    @Test func chatToolSchemasAreStrict() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let schema = try JSONDecoder().decode(
            GenerationSchema.self,
            from: Data(#"{"type":"object","properties":{}}"#.utf8)
        )
        let tool = LlamaOpenAICompatibleChatTool(
            function: .init(
                name: "get_weather",
                description: "Get the weather",
                parameters: schema
            )
        )

        let body = try encodedObject(tool)
        let function = try #require(body["function"] as? [String: Any])
        #expect(function["strict"] as? Bool == true)
    }

    @Test func imageAndResponseFormatUseChatSchema() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let schema = try JSONDecoder().decode(
            GenerationSchema.self,
            from: Data(#"{\"title\":\"Weather\",\"type\":\"object\",\"properties\":{}}"#.utf8)
        )
        let request = LlamaOpenAICompatibleChatCompletionRequest(
            model: "test-model",
            messages: [
                LlamaOpenAICompatibleChatMessage(
                    role: .user,
                    content: [
                        LlamaOpenAICompatibleChatMessageContent(
                            imageURL: .init(url: URL(string: "data:image/png;base64,AA==")!)
                        )
                    ]
                )
            ],
            temperature: nil,
            topP: nil,
            maxCompletionTokens: nil,
            tools: nil,
            toolChoice: nil,
            responseFormat: LlamaOpenAICompatibleChatResponseFormat(
                jsonSchema: .init(name: "Weather", schema: schema)
            )
        )

        let body = try encodedObject(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image_url")
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
    }

    @Test func chatChunkDecodesTelemetryMetadata() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let data = #"""
        {
          "choices": [{"index": 0, "delta": {"content": "Hi"}}],
          "timings": { "prompt_n": 4, "predicted_n": 1 },
          "prompt_progress": { "processed_tokens": 2, "total_tokens": 4 }
        }
        """#.data(using: .utf8)!

        let chunk = try JSONDecoder().decode(
            LlamaOpenAICompatibleChatCompletionChunk<LlamaOpenAICompatibleTelemetryFields>.self,
            from: data
        )
        let metadata = try #require(chunk.metadata)
        let timings = try #require(metadata.values[LlamaTelemetryMetadataKeys.timings.rawValue] as? LlamaTimings)
        let progress = try #require(metadata.values[LlamaTelemetryMetadataKeys.promptProgress.rawValue] as? LlamaPromptProgress)

        #expect(timings.promptTokens == 4)
        #expect(timings.predictedTokens == 1)
        #expect(progress.processedTokens == 2)
        #expect(progress.totalTokens == 4)
    }

    @Test func streamProcessesTextReasoningAndParallelToolsFromOneChunk() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let data = #"""
        {
          "choices": [{
            "index": 0,
            "delta": {
              "content": "Calling tools",
              "reasoning_content": "Need both",
              "tool_calls": [
                {"index": 0, "id": "call_a", "function": {"name": "tool_a", "arguments": "{}"}},
                {"index": 1, "id": "call_b", "function": {"name": "tool_b", "arguments": "{}"}}
              ]
            }
          }],
          "usage": {"prompt_tokens": 8, "completion_tokens": 3},
          "timings": {"prompt_n": 8, "predicted_n": 3}
        }
        """#.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(
            LlamaOpenAICompatibleChatCompletionChunk<LlamaOpenAICompatibleTelemetryFields>.self,
            from: data
        )
        let chunks = AsyncStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
        let channel = LanguageModelExecutorGenerationChannel()

        try await LlamaOpenAICompatibleGenerationStreamProcessor.process(chunks, into: channel)

        var iterator = channel.makeAsyncIterator()
        for _ in 0..<6 {
            _ = try #require(await iterator.next())
        }
    }

    private func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedJSONArray(_ value: some Encodable) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
