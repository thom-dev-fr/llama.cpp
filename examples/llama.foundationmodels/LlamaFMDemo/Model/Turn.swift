import Foundation
import FoundationModels

/// What the user asked in one turn, with the options it was sent with:
/// "Retry" submits exactly this again.
struct TurnRequest: Sendable {
    enum Kind: String, Sendable, CaseIterable, Identifiable {
        /// Streamed text answer.
        case chat
        /// A `CityGuide` generated as structured output.
        case cityGuide

        var id: Self { self }
        var title: String {
            switch self {
            case .chat: "Chat"
            case .cityGuide: "City guide"
            }
        }
    }

    var kind: Kind
    var text: String
    var images: [PromptImage]
    var options: GenerationOptions
    var contextOptions: ContextOptions

    /// The prompt: text, then the images in their order.
    var prompt: Prompt {
        let text = kind == .cityGuide ? "Write a short guide to this city: \(self.text)" : self.text
        let images = self.images
        return Prompt {
            text
            for image in images {
                image.attachment
            }
        }
    }
}

/// One exchange as the conversation displays it. Its content comes from the
/// response stream; an interrupted turn keeps its fragments here only: the
/// session transcript, which is authoritative, goes back to the last complete
/// turn.
struct Turn: Identifiable {
    enum Status: Equatable {
        case running
        case complete
        case interrupted(Interruption)
    }

    struct Interruption: Equatable {
        /// Cancelled (by the user or the application), not failed.
        var isCancellation: Bool
        var message: String
        /// The diagnostic of the engine or the framework, when there is one.
        var detail: String?
    }

    /// An entry of the transcript produced for this turn.
    enum Item: Identifiable, Equatable {
        case reasoning(id: String, text: String)
        case toolCalls(id: String, calls: [ToolCall])
        case toolOutput(id: String, tool: String, text: String)
        case response(id: String, text: String)

        var id: String {
            switch self {
            case .reasoning(let id, _), .toolCalls(let id, _), .toolOutput(let id, _, _), .response(let id, _): id
            }
        }
    }

    struct ToolCall: Equatable, Identifiable {
        var id: String
        var tool: String
        var arguments: String
    }

    /// Token counts of this response, as reported to the session: a
    /// consumption, not the occupancy of the context.
    struct Usage: Equatable {
        var input: Int
        var cachedInput: Int
        var output: Int
        var reasoning: Int

        init(_ usage: LanguageModelSession.Usage) {
            input = usage.input.totalTokenCount
            cachedInput = usage.input.cachedTokenCount
            output = usage.output.totalTokenCount
            reasoning = usage.output.reasoningTokenCount
        }
    }

    let id = UUID()
    let request: TurnRequest
    var items: [Item] = []
    /// The streamed text answer (chat).
    var text = ""
    /// The structured answer so far (city guide).
    var guide: CityGuide.PartiallyGenerated?
    var status = Status.running
    var usage: Usage?

    var isInterrupted: Bool {
        if case .interrupted = status { return true }
        return false
    }

    /// Items to display before the answer: every entry except the last
    /// response, which the streamed answer (`text` or `guide`) shows.
    var itemsBeforeAnswer: [Item] {
        guard let last = items.lastIndex(where: { if case .response = $0 { true } else { false } }) else { return items }
        var result = items
        result.remove(at: last)
        return result
    }

    mutating func apply(_ entries: some Sequence<Transcript.Entry>) {
        items = entries.compactMap(Self.item)
    }

    static func item(_ entry: Transcript.Entry) -> Item? {
        switch entry {
        case .reasoning(let reasoning):
            return .reasoning(id: reasoning.id, text: text(reasoning.segments))
        case .toolCalls(let calls):
            return .toolCalls(id: calls.id, calls: calls.map {
                ToolCall(id: $0.id, tool: $0.toolName, arguments: $0.arguments.jsonString)
            })
        case .toolOutput(let output):
            return .toolOutput(id: output.id + "-output", tool: output.toolName, text: text(output.segments))
        case .response(let response):
            return .response(id: response.id, text: text(response.segments))
        case .instructions, .prompt:
            return nil
        @unknown default:
            return nil
        }
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment: nil
            @unknown default: nil
            }
        }.joined()
    }
}
