import Foundation
@testable import LlamaEngine
import Testing

// P2: the Swift layer over the C bridge with a real engine and a small local
// model (CPU). The simulator reads the repository's test fixture directly.

private let model = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../tools/server/tests/tmp/stories15M-q4_0.gguf").standardizedFileURL.path

private func configuration(parallel: Int = 1) -> Data {
    let json: [String: Any] = [
        "max_loaded": 1, "max_waiting": 4,
        "models": [[
            "id": "m",
            "settings": [
                "model_path": model, "context_size": 256, "parallel": parallel, "gpu_layers": 0,
                "chat_template": "chatml", "options": ["context-shift": true],
            ],
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func chat(maxTokens: Int) -> Data {
    let json: [String: Any] = [
        "model": "m", "messages": [["role": "user", "content": "Hello"]],
        "max_tokens": maxTokens, "temperature": 0, "ignore_eos": true, "stream": true,
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

/// Reads until the terminal event; counts payloads.
private func drain(_ request: NativeRequest) async throws -> (payloads: Int, end: NativeEvent) {
    var payloads = 0
    while true {
        let event = try await request.next()
        if event.isTerminal { return (payloads, event) }
        if event.kind == .payload { payloads += 1 }
    }
}

@Suite(.serialized) struct NativeEngineTests {
    let workers = NativeWorkers()

    @Test func modelFixtureIsReadable() {
        #expect(FileManager.default.isReadableFile(atPath: model), "missing fixture \(model)")
    }

    @Test func invalidConfigurationThrowsTypedError() async {
        do {
            _ = try await NativeEngine.create(configuration: Data("{".utf8), workers: workers)
            Issue.record("expected an error")
        } catch let LlamaEngineError.native(category, _, _) {
            #expect(category == "invalid_request")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func streamedChatLoadsOnDemand() async throws {
        let engine = try await NativeEngine.create(configuration: configuration(), workers: workers)
        let catalog = String(decoding: try engine.catalog(), as: UTF8.self)
        #expect(catalog.contains("\"unloaded\""))
        let request = try await engine.submit("chat", body: chat(maxTokens: 8))
        let (payloads, end) = try await drain(request)
        #expect(end.kind == .success)
        #expect(payloads > 1)
        #expect(String(decoding: try engine.catalog(), as: UTF8.self).contains("\"loaded\""))
        await engine.stop()
    }

    @Test func eventsStreamEndsWithSuccess() async throws {
        let engine = try await NativeEngine.create(configuration: configuration(), workers: workers)
        var kinds: [NativeEvent.Kind] = []
        for try await event in try await engine.submit("chat", body: chat(maxTokens: 4)).events() {
            kinds.append(event.kind)
        }
        #expect(kinds.last == .success)
        #expect(kinds.dropLast().allSatisfy { $0 == .payload })
    }

    @Test func taskCancellationCancelsTheNativeRequest() async throws {
        let engine = try await NativeEngine.create(configuration: configuration(), workers: workers)
        let request = try await engine.submit("chat", body: chat(maxTokens: -1)) // endless (context shift)
        let reader = Task { try await drain(request) }
        _ = try await engine.submit("tokenize", body: Data("{\"model\":\"m\",\"content\":\"x\"}".utf8)).next()
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        let (_, end) = try await reader.value
        #expect(end.kind == .cancelled)
        #expect(end.category == "cancelled")
    }

    @Test func blockedReadersLeaveTheCooperativePoolFree() async throws {
        let engine = try await NativeEngine.create(configuration: configuration(), workers: workers)
        // One endless generation holds the only slot.
        let busy = try await engine.submit("chat", body: chat(maxTokens: -1))
        #expect(try await busy.next().kind == .payload)
        let busyReader = Task { try await drain(busy) }
        // More readers blocked in the native next than cores: they would starve
        // the cooperative pool if they ran on it.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        var waiting: [NativeRequest] = []
        for _ in 0..<count { waiting.append(try await engine.submit("chat", body: chat(maxTokens: 4))) }
        let clock = ContinuousClock()
        let readers = waiting.map { request in Task { () -> (NativeEvent, Duration) in
            let start = clock.now
            let (_, end) = try await drain(request)
            return (end, clock.now - start)
        } }
        try await Task.sleep(for: .milliseconds(300)) // the readers wait natively
        let start = clock.now
        let answered = await Task.detached { 42 }.value
        let elapsed = clock.now - start
        #expect(answered == 42)
        #expect(elapsed < .milliseconds(100), "cooperative pool blocked for \(elapsed)")
        // Unload ends all of them; the model stays in the catalog.
        let unloaded = await engine.unload(model: "m")
        #expect(unloaded.kind == .success)
        for reader in readers {
            let (end, waited) = try await reader.value
            #expect(end.kind == .cancelled)
            #expect(waited >= .milliseconds(250)) // really waited natively
        }
        #expect(try await busyReader.value.end.category == "unloaded")
        #expect(String(decoding: try engine.catalog(), as: UTF8.self).contains("\"unloaded\""))
    }

    @Test func requestOutlivesItsEngine() async throws {
        var engine: NativeEngine? = try await NativeEngine.create(configuration: configuration(), workers: workers)
        let request = try await engine!.submit("chat", body: chat(maxTokens: -1))
        let reader = Task { try await drain(request) }
        try await Task.sleep(for: .milliseconds(200))
        await engine!.stop()
        engine = nil // destroyed on a worker
        let (_, end) = try await reader.value
        #expect(end.kind == .cancelled)
        #expect(end.category == "stopped")
        #expect(try await request.next().kind == .cancelled) // same terminal, immediately
    }

    @Test func concurrentReadersAreRefused() async throws {
        let engine = try await NativeEngine.create(configuration: configuration(), workers: workers)
        let request = try await engine.submit("chat", body: chat(maxTokens: -1))
        let first = Task { try await drain(request) }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: LlamaEngineError.concurrentReaders) { _ = try await request.next() }
        request.cancel()
        _ = try await first.value
    }
}
