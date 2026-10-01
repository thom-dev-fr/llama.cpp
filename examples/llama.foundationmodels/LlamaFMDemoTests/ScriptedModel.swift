import Foundation
import FoundationModels
@testable import LlamaFMDemo

/// What a scripted model answers, request after request, and the requests
/// it received (the transcript Foundation Models really submitted).
final class Script: @unchecked Sendable {
    enum Step {
        /// Response fragments, then a normal end.
        case text([String])
        /// Fragments, then an error.
        case fail([String], any Error)
        /// Fragments, then waits until cancelled.
        case hang([String])
        /// Fragments spaced by a delay.
        case slow([String], Duration)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var received: [LanguageModelExecutorGenerationRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var requests: [LanguageModelExecutorGenerationRequest] { lock.withLock { received } }

    func next(_ request: LanguageModelExecutorGenerationRequest) -> Step {
        lock.withLock {
            received.append(request)
            return steps.isEmpty ? .text(["(no more steps)"]) : steps.removeFirst()
        }
    }
}

/// A `LanguageModel` that plays a `Script`: drives the real Foundation Models
/// session (transcript, rollback, streaming) without an engine.
struct ScriptedModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    let script: Script
    var declared: [LanguageModelCapabilities.Capability] = [.guidedGeneration]

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities(declared) }
    var executorConfiguration: ScriptedExecutor.Configuration { .init(script: script) }
}

struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedModel

    struct Configuration: Hashable, Sendable {
        let script: Script
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.script === rhs.script }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(script)) }
    }

    init(configuration: Configuration) throws {}

    nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
                                         streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        func send(_ fragments: [String]) async {
            for fragment in fragments {
                await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
            }
        }
        switch model.script.next(request) {
        case .text(let fragments):
            await send(fragments)
        case .fail(let fragments, let error):
            await send(fragments)
            throw error
        case .hang(let fragments):
            await send(fragments)
            try await Task.sleep(for: .seconds(600))
        case .slow(let fragments, let delay):
            for fragment in fragments {
                await send([fragment])
                try await Task.sleep(for: delay)
            }
        }
    }
}

extension Transcript {
    /// Prompt texts and response texts, in order.
    var exchanges: [String] {
        compactMap { entry in
            switch entry {
            case .prompt(let prompt): "prompt:" + Turn.text(prompt.segments)
            case .response(let response): "response:" + Turn.text(response.segments)
            default: nil
            }
        }
    }
}

@MainActor
func until(_ timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
