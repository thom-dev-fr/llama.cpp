import Foundation
import FoundationModels
@testable import LlamaFMDemo
import LlamaEngine
import LlamaFoundationModels
import SwiftUI
import Testing

// The presentation model against a scripted model: the real Foundation Models
// session decides the transcript; the demo keeps interrupted fragments apart.

@MainActor
private func conversation(_ script: Script, capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration])
    -> Conversation {
    Conversation(modelID: LlamaModelID("scripted"), modelName: "Scripted", profile: nil,
                 model: ScriptedModel(script: script, declared: capabilities), monitor: nil)
}

@MainActor
private func request(_ conversation: Conversation, _ text: String, kind: TurnRequest.Kind = .chat) -> TurnRequest {
    conversation.makeRequest(kind: kind, text: text, images: [], settings: DemoSettings())
}

@MainActor @Suite struct ConversationTests {
    @Test func streamedAnswerCompletes() async throws {
        let script = Script([.text(["Bon", "jour ", "🌍"])])
        let chat = conversation(script)
        #expect(chat.send(request(chat, "Hello")))
        #expect(chat.isResponding)
        await chat.waitUntilIdle()
        let turn = try #require(chat.turns.last)
        #expect(turn.status == .complete)
        #expect(turn.text == "Bonjour 🌍")
        #expect(!chat.isResponding)
        #expect(chat.transcript.exchanges == ["prompt:Hello", "response:Bonjour 🌍"])
    }

    @Test func errorAfterFragmentsKeepsThemOutOfTheTranscript() async throws {
        let script = Script([
            .text(["first"]),
            .fail(["par", "tial"], LlamaEngineError.unloaded(LlamaModelID("scripted"))),
            .text(["second"]),
        ])
        let chat = conversation(script)
        chat.send(request(chat, "one"))
        await chat.waitUntilIdle()
        chat.send(request(chat, "two"))
        await chat.waitUntilIdle()

        let failed = try #require(chat.turns.last)
        guard case .interrupted(let interruption) = failed.status else {
            Issue.record("not interrupted: \(failed.status)")
            return
        }
        #expect(!interruption.isCancellation)
        #expect(interruption.message.contains("unloaded"))
        #expect(failed.text == "partial")                     // the fragments stay visible
        #expect(chat.transcript.exchanges == ["prompt:one", "response:first"])
        #expect(chat.canRetry)

        chat.retry()
        chat.retry()                                          // ignored: the retry is running
        await chat.waitUntilIdle()
        #expect(script.requests.count == 3)                   // submitted once
        #expect(script.requests[2].transcript.exchanges == ["prompt:one", "response:first", "prompt:two"])
        #expect(chat.turns.count == 3)
        #expect(chat.turns[1].isInterrupted && chat.turns[1].text == "partial")
        #expect(chat.turns[2].status == .complete && chat.turns[2].text == "second")
        #expect(chat.transcript.exchanges == ["prompt:one", "response:first", "prompt:two", "response:second"])
        #expect(!chat.canRetry)
    }

    @Test func cancellationIsAnInterruption() async throws {
        // the last fragment before the wait stays withheld by the session
        let script = Script([.hang(["frag", "ment", "!"]), .text(["done"])])
        let chat = conversation(script)
        chat.send(request(chat, "long"))
        #expect(!chat.send(request(chat, "concurrent")))       // one turn at a time
        try await until { script.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        chat.cancel(reason: LifecyclePolicy.backgroundReason)
        await chat.waitUntilIdle()
        let turn = try #require(chat.turns.last)
        #expect(turn.status == .interrupted(.init(isCancellation: true, message: LifecyclePolicy.backgroundReason)),
                "\(turn.status)")
        #expect(turn.text.hasPrefix("fragment"))
        #expect(chat.transcript.exchanges.isEmpty)
        chat.retry()
        await chat.waitUntilIdle()
        #expect(script.requests.last?.transcript.exchanges == ["prompt:long"])
        #expect(chat.turns.map(\.text.count) == [turn.text.count, 4], "\(chat.turns.map(\.text))")
    }

    /// The text is displayed while it streams. Observed SDK behaviour: the
    /// session withholds the latest event; a fragment shows when the next
    /// one arrives, or at the end.
    @Test func fragmentsShowBeforeTheEnd() async throws {
        let chat = conversation(Script([.slow(["a", "b", "c", "d", "e", "f"], .milliseconds(150))]))
        chat.send(request(chat, "x"))
        var seen: [String] = []
        while chat.isResponding {
            if let text = chat.turns.last?.text, seen.last != text { seen.append(text) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.turns.last?.text == "abcdef")
        #expect(seen.contains { !$0.isEmpty && $0 != "abcdef" }, "\(seen)")
        #expect(!seen.contains("abcdef"), "\(seen)")   // the last fragment shows only at the end
    }

    @Test func contextOverflowIsExplained() async throws {
        let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 256, tokenCount: 300,
                                                                    debugDescription: "context full during prompt"))
        let chat = conversation(Script([.fail([], overflow)]))
        chat.send(request(chat, "too long"))
        await chat.waitUntilIdle()
        guard case .interrupted(let interruption)? = chat.turns.last?.status else {
            Issue.record("not interrupted")
            return
        }
        #expect(interruption.message.contains("300 tokens needed, 256 available"))
        #expect(interruption.detail == "context full during prompt")
    }

    @Test func structuredAnswerStreamsIntoTheGuide() async throws {
        let json = #"{"name": "Lyon", "country": "France", "population": 520000, "#
            + #""landmarks": ["Fourvière", "Vieux Lyon", "Parc de la Tête d'Or"], "summary": "A city of food."}"#
        let chunks = stride(from: 0, to: json.count, by: 9).map { start in
            String(json.dropFirst(start).prefix(9))
        }
        let chat = conversation(Script([.text(chunks)]))
        chat.send(request(chat, "Lyon", kind: .cityGuide))
        await chat.waitUntilIdle()
        let guide = try #require(chat.turns.last?.guide)
        #expect(chat.turns.last?.status == .complete)
        #expect(guide.name == "Lyon")
        #expect(guide.population == 520000)
        #expect(guide.landmarks?.count == 3)
    }

    @Test func requestsFollowTheCapabilities() {
        let plain = conversation(Script([]))
        var settings = DemoSettings()
        settings.reasoning = true
        settings.tools = true
        let a = plain.makeRequest(kind: .chat, text: "x", images: [], settings: settings)
        #expect(a.options.toolCallingMode == nil)             // no tools without the capability
        #expect(a.contextOptions.reasoningLevel == nil)
        #expect(plain.refusal(images: [try! testImage()]) != nil)

        let capable = conversation(Script([]), capabilities: [.guidedGeneration, .toolCalling, .reasoning, .vision])
        settings.tools = false
        settings.reasoning = false
        let b = capable.makeRequest(kind: .cityGuide, text: "x", images: [], settings: settings)
        #expect(b.options.toolCallingMode == .disallowed)
        #expect(b.contextOptions.reasoningLevel == .custom("none"))
        #expect(b.contextOptions.includeSchemaInPrompt == true)
        settings.reasoning = true
        let c = capable.makeRequest(kind: .cityGuide, text: "x", images: [], settings: settings)
        #expect(c.contextOptions.reasoningLevel == nil)       // the template's default: Qwen3.5 reasons
        #expect(c.contextOptions.includeSchemaInPrompt == false)
        #expect(capable.refusal(images: [try! testImage()]) == nil)
    }
}

@MainActor
private func testImage() throws -> PromptImage {
    let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return PromptImage(cgImage: context.makeImage()!, orientation: .right)
}

@Suite struct LifecycleTests {
    @Test func onlyTheRealBackgroundCancelsOnIOS() {
        #expect(LifecyclePolicy.cancelsInference(from: .active, to: .background, on: .iOS))
        #expect(LifecyclePolicy.cancelsInference(from: .inactive, to: .background, on: .iOS))
        // a picker or the app switcher: transitional
        #expect(!LifecyclePolicy.cancelsInference(from: .active, to: .inactive, on: .iOS))
        #expect(!LifecyclePolicy.cancelsInference(from: .inactive, to: .active, on: .iOS))
        #expect(!LifecyclePolicy.cancelsInference(from: .background, to: .inactive, on: .iOS))
        // macOS: never
        #expect(!LifecyclePolicy.cancelsInference(from: .active, to: .background, on: .macOS))
        #expect(!LifecyclePolicy.cancelsInference(from: .active, to: .inactive, on: .macOS))
    }
}

@Suite struct IndicatorTests {
    @Test func noMeasureIsUnavailableNotZero() {
        let gauge = ContextGauge(.initial)
        #expect(gauge.value == .unavailable)
        #expect(gauge.fraction == nil)
        #expect(gauge.label == "Unavailable")
    }

    @Test func liveAndLastMeasures() {
        var state = LlamaGenerationMonitor.State.initial
        state.context = LlamaContextReport(contextSize: 4096, occupiedTokens: 1024, promptTokens: 1000, cachedTokens: 0,
                                           generatedTokens: 24, reasoningTokens: 0)
        state.isContextLive = true
        state.phase = .generating
        let live = ContextGauge(state)
        #expect(live.fraction == 0.25)
        #expect(live.caption == "Current request")
        state.isContextLive = false
        state.phase = .idle
        #expect(ContextGauge(state).caption == "Last measure")
        #expect(ContextGauge(state).fraction == 0.25)
        #expect(ActivityStatus(monitor: state, model: nil, profile: nil, admission: nil) == nil)
    }

    @Test func promptProgress() {
        var state = LlamaGenerationMonitor.State.initial
        state.phase = .processingPrompt
        state.promptProgress = 0.5
        let status = ActivityStatus(monitor: state, model: nil, profile: nil, admission: nil)
        #expect(status?.phase == .processingPrompt)
        #expect(status?.progress == 0.5)
    }
}

@Suite struct ToolTests {
    @Test func calculator() async throws {
        let tool = CalculatorTool()
        #expect(try await tool.call(arguments: .init(expression: "(12+3)*4")) == "60")
        #expect(try await tool.call(arguments: .init(expression: "6 * 7")) == "42")
        #expect(try await tool.call(arguments: .init(expression: "-5/2")) == "-2.5")
        #expect(try await tool.call(arguments: .init(expression: "1/0")).hasPrefix("error: division by zero"))
        #expect(try await tool.call(arguments: .init(expression: "2*(3")).hasPrefix("error:"))
    }

    @Test func productLookup() async throws {
        let tool = ProductLookupTool()
        #expect(try await tool.call(arguments: .init(product: "Pens")) == "pen: 3.00 EUR, 120 in stock")
        #expect(try await tool.call(arguments: .init(product: "lamp")) == "lamp: 24.50 EUR, 0 in stock")
        #expect(try await tool.call(arguments: .init(product: "car")).hasPrefix("unknown product"))
    }
}
