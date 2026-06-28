import Foundation

struct ToolCallDelta {
    var index: Int
    var id: String?
    var name: String?
    var argumentsDelta: String = ""
}

struct ChunkParts {
    var content: String = ""
    var reasoning: String = ""
    var toolCallDeltas: [ToolCallDelta] = []
    var finishReason: String? = nil
}

enum ChatCompletionStreamParser {
    static func parse(_ chunk: String) -> ChunkParts {
        var parts = ChunkParts()
        guard let data = chunk.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else {
            return parts
        }

        let objects: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            objects = arr
        } else if let obj = raw as? [String: Any] {
            objects = [obj]
        } else {
            return parts
        }

        for obj in objects {
            guard let choices = obj["choices"] as? [[String: Any]] else { continue }
            for choice in choices {
                if let reason = choice["finish_reason"] as? String {
                    parts.finishReason = reason
                }

                let container = (choice["delta"] as? [String: Any])
                             ?? (choice["message"] as? [String: Any])
                             ?? [:]

                if let s = container["content"] as? String {
                    parts.content += s
                }
                if let s = container["reasoning_content"] as? String {
                    parts.reasoning += s
                }
                if let tcArr = container["tool_calls"] as? [[String: Any]] {
                    for tc in tcArr {
                        let idx = (tc["index"] as? Int) ?? 0
                        var delta = ToolCallDelta(index: idx)
                        delta.id = tc["id"] as? String
                        if let fn = tc["function"] as? [String: Any] {
                            delta.name = fn["name"] as? String
                            if let a = fn["arguments"] as? String {
                                delta.argumentsDelta = a
                            }
                        }
                        parts.toolCallDeltas.append(delta)
                    }
                }
            }
        }
        return parts
    }
}
