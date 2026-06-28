import Foundation

struct ChatRequestBuilder {
    var systemPrompt: String
    var messages: [ChatMessage]
    var temperature: Double
    var enableTools: Bool

    func build(stream: Bool) -> String {
        var oaiMessages: [[String: Any]] = []

        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            oaiMessages.append(["role": "system", "content": sys])
        }

        for message in messages {
            if message.role == .assistant && message.isStreaming { continue }
            switch message.role {
            case .system:
                continue
            case .user:
                oaiMessages.append(["role": "user", "content": userContent(for: message)])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant"]
                entry["content"] = message.content
                if message.hasToolCalls {
                    entry["tool_calls"] = message.toolCalls.map { toolCall -> [String: Any] in
                        [
                            "id": toolCall.id,
                            "type": "function",
                            "function": [
                                "name": toolCall.name,
                                "arguments": toolCall.arguments,
                            ],
                        ]
                    }
                }
                oaiMessages.append(entry)
            case .tool:
                oaiMessages.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "name": message.toolName ?? "",
                    "content": message.content,
                ])
            }
        }

        var payload: [String: Any] = [
            "messages": oaiMessages,
            "temperature": temperature,
            "stream": stream,
            "reasoning_format": "deepseek",
        ]
        if enableTools {
            payload["tools"] = ToolRegistry.oaiToolsArray()
            payload["tool_choice"] = "auto"
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func userContent(for message: ChatMessage) -> Any {
        guard message.hasAttachments else {
            return message.content
        }

        var parts: [[String: Any]] = []
        if !message.content.isEmpty {
            parts.append(["type": "text", "text": message.content])
        }
        for attachment in message.attachments {
            switch attachment.kind {
            case .image(let mime):
                let b64 = attachment.data.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(b64)"],
                ])
            case .audio(let format):
                parts.append([
                    "type": "input_audio",
                    "input_audio": [
                        "data": attachment.data.base64EncodedString(),
                        "format": format,
                    ],
                ])
            }
        }
        return parts
    }
}
