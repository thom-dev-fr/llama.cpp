import Foundation
import FoundationModels
import LlamaEngine

/// Translates the streamed chat deltas of the engine into channel events, in
/// order: reasoning, response text and tool call arguments as they come.
///
/// Deltas are complete UTF-8 strings (the engine holds back an incomplete
/// sequence). The response is one segment, extended by `appendText`. Tool call
/// arguments are forwarded as fragments; a call is only complete when its JSON
/// is, which `finish` checks.
struct StreamTranslation {
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    struct ToolCall {
        var id: String
        var name: String
        var arguments = ""
    }

    private(set) var toolCalls: [Int: ToolCall] = [:]
    private(set) var toolCallOrder: [Int] = []
    private(set) var finishReason: String?
    /// Latest context report of the request.
    private(set) var report: LlamaContextReport?
    /// Latest prompt progress (processed share of the prompt).
    private(set) var promptProgress: Double?
    private(set) var hasGenerated = false
    private var decoded = 0

    /// Events of one engine payload (one chunk, or an ordered array of chunks).
    mutating func translate(payload: Data) throws -> [Event] {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: payload)
        } catch {
            throw LlamaLanguageModelError.invalidEngineOutput("a streamed payload is not JSON")
        }
        var events: [Event] = []
        for chunk in value.arrayValue ?? [value] {
            events += try translate(chunk: chunk)
        }
        return events
    }

    private mutating func translate(chunk: JSONValue) throws -> [Event] {
        var tokens = 0
        if let context = chunk["context"], let report = try? JSONDecoder().decode(LlamaContextReport.self, from: context.data) {
            self.report = report
            tokens = max(0, report.generatedTokens - decoded)
            decoded = max(decoded, report.generatedTokens)
        }
        if let progress = chunk["prompt_progress"], let total = progress["total"]?.intValue, total > 0,
           let processed = progress["processed"]?.intValue {
            promptProgress = min(1, Double(processed) / Double(total))
        }
        if let error = chunk["error"] {
            throw LlamaLanguageModelError.invalidEngineOutput("error inside a streamed chunk: \(error.serialized)")
        }
        guard let choice = chunk["choices"]?.arrayValue?.first else {
            return []
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
        }
        guard let delta = choice["delta"] else {
            return []
        }
        // The tokens of the chunk are counted once, on its first event.
        func take() -> Int {
            defer { tokens = 0 }
            return tokens
        }
        var events: [Event] = []
        if let reasoning = delta["reasoning_content"]?.stringValue, !reasoning.isEmpty {
            events.append(.reasoning(action: .appendText(reasoning, tokenCount: take())))
        }
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            events.append(.response(action: .appendText(content, tokenCount: take())))
        }
        for call in delta["tool_calls"]?.arrayValue ?? [] {
            let index = call["index"]?.intValue ?? 0
            let function = call["function"]
            var current: ToolCall
            if let known = toolCalls[index] {
                current = known
            } else {
                guard let id = call["id"]?.stringValue, let name = function?["name"]?.stringValue else {
                    throw LlamaLanguageModelError.invalidEngineOutput("a tool call starts without id or name")
                }
                current = ToolCall(id: id, name: name)
                toolCallOrder.append(index)
            }
            let fragment = function?["arguments"]?.stringValue ?? ""
            current.arguments += fragment
            let isNew = toolCalls[index] == nil
            toolCalls[index] = current
            if isNew || !fragment.isEmpty {
                events.append(.toolCalls(action: .toolCall(id: current.id, name: current.name,
                                                           action: .appendArguments(fragment, tokenCount: take()))))
            }
        }
        if !events.isEmpty {
            hasGenerated = true
        }
        return events
    }

    /// The last events, after the engine's success: usage, once the tool
    /// calls are known to be complete.
    func finish() throws -> [Event] {
        for index in toolCallOrder {
            let call = toolCalls[index]!
            if (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] == nil {
                let reason = finishReason == "length" ? "the output token limit was reached" : "its arguments are not a JSON object"
                throw LlamaLanguageModelError.incompleteToolCall(name: call.name, reason: reason)
            }
        }
        guard let report else {
            return []
        }
        let input = LanguageModelExecutorGenerationChannel.Usage.Input(
            totalTokenCount: report.promptTokens, cachedTokenCount: report.cachedTokens)
        let output = LanguageModelExecutorGenerationChannel.Usage.Output(
            totalTokenCount: report.generatedTokens, reasoningTokenCount: report.reasoningTokens)
        if toolCallOrder.isEmpty {
            return [.response(action: .updateUsage(input: input, output: output))]
        }
        return [.toolCalls(action: .updateUsage(input: input, output: output))]
    }
}
