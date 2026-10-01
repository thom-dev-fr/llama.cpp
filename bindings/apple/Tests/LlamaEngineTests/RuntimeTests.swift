import Foundation
@testable import LlamaEngine
import Testing

// P3: the shared runtime with the real engine and a small local model (CPU):
// admission, shared instances, unload, observation, model store.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../tools/server/tests/tmp/stories15M-q4_0.gguf").standardizedFileURL

private let stories = LlamaModelID("stories")

/// CPU, chatml (the fixture has no template); context shift makes a
/// generation without token limit run until cancelled.
private let profile = LlamaLoadProfile(contextSize: 128, compute: LlamaComputeConfiguration(offload: .none),
                                       chatTemplate: "chatml", engineOptions: ["context-shift": "true"])

private func chat(_ messages: [[String: String]] = [["role": "user", "content": "Hello"]], maxTokens: Int) -> Data {
    let json: [String: Any] = [
        "messages": messages, "max_tokens": maxTokens, "temperature": 0, "ignore_eos": true, "stream": true,
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func runtime(_ limits: LlamaRuntime.Limits = LlamaRuntime.Limits(), store: LlamaModelStore? = nil,
                     bufferLimit: Int = 64) throws -> LlamaRuntime {
    let runtime = try LlamaRuntime(configuration: LlamaRuntime.Configuration(limits: limits, observationBufferLimit: bufferLimit),
                                   store: store)
    if store == nil {
        try runtime.register(LlamaModelArtifact(id: stories, weights: [fixture]))
    }
    return runtime
}

/// Reads a generation to its end; counts payloads.
@discardableResult
private func drain(_ generation: LlamaGeneration) async throws -> Int {
    var payloads = 0
    for try await event in generation.events() where event.kind == .payload {
        payloads += 1
    }
    return payloads
}

/// Generates and reads to the end.
@discardableResult
private func run(_ runtime: LlamaRuntime, _ body: Data, profile: LlamaLoadProfile = profile) async throws -> Int {
    try await drain(try await runtime.generate(model: stories, profile: profile, body: body))
}

/// Reads until the first payload: the generation is running.
private func started(_ generation: LlamaGeneration) async throws {
    while let event = try await generation.next(), event.kind != .payload {}
}

/// Native transitions into "loading" per catalog entry, read from a
/// subscription until it stays quiet. (The engine repeats the status when a
/// request joins a load in progress: only changes count.)
private func loads(_ subscription: NativeSubscription) async -> [String: Int] {
    var counts: [String: Int] = [:]
    var last: [String: String] = [:]
    while true {
        let event = await subscription.next(timeout: .milliseconds(300))
        guard event.kind == .payload else { return counts }
        if let json = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any],
           json["type"] as? String == "status", let status = json["status"] as? String, let model = json["model"] as? String {
            if status == "loading" && last[model] != "loading" {
                counts[model, default: 0] += 1
            }
            last[model] = status
        }
    }
}

private func until(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("llama-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fakeGGUF(_ url: URL, bytes: Int = 64) throws {
    try (Data("GGUF".utf8) + Data(repeating: 7, count: bytes)).write(to: url)
}

@Suite(.serialized) struct RuntimeTests {
    @Test func configurationIsValidated() {
        #expect(throws: LlamaEngineError.self) {
            _ = try LlamaRuntime(configuration: .init(limits: .init(maximumActiveGenerations: 0)))
        }
        #expect(throws: LlamaEngineError.self) {
            _ = try LlamaRuntime(configuration: .init(limits: .init(maximumWaitingRequests: -1)))
        }
        #expect(throws: LlamaEngineError.invalidConfiguration("invalid model identifier 'a/b'")) {
            try LlamaRuntime().register(LlamaModelArtifact(id: LlamaModelID("a/b"), weights: [fixture]))
        }
    }

    @Test func instanceIdentityFollowsArtifactAndProfile() {
        let a = InstanceKey(model: stories, profile: profile)
        var other = profile
        other.contextSize = 64
        #expect(a.entryID == InstanceKey(model: stories, profile: profile).entryID)
        #expect(a.entryID != InstanceKey(model: stories, profile: other).entryID)
        #expect(a.entryID != InstanceKey(model: LlamaModelID("other"), profile: profile).entryID)
        other = profile
        other.engineOptions["cache-type-k"] = "q8_0"
        #expect(a.entryID != InstanceKey(model: stories, profile: other).entryID)
    }

    @Test func twoSessionsShareOneInstance() async throws {
        let runtime = try runtime(.init(maximumResidentModels: 2, maximumActiveGenerations: 2))
        let subscription = try runtime.native.subscribe()
        // Two independent conversations, interleaved, on the same model and profile.
        async let first = run(runtime, chat([["role": "user", "content": "Tell me about cats"]], maxTokens: 8))
        async let second = run(runtime, chat([["role": "user", "content": "Tell me about dogs"]], maxTokens: 8))
        #expect(try await first > 0)
        #expect(try await second > 0)
        let entry = InstanceKey(model: stories, profile: profile).entryID
        #expect(await loads(subscription) == [entry: 1]) // one load for both
        try await until { runtime.snapshot()[stories]?.instances.first?.state == .loaded }
        #expect(runtime.snapshot()[stories]?.instances.count == 1)

        // An incompatible profile gets its own instance; the first one stays.
        var other = profile
        other.contextSize = 64
        try await run(runtime, chat(maxTokens: 4), profile: other)
        let otherEntry = InstanceKey(model: stories, profile: other).entryID
        #expect(await loads(subscription) == [otherEntry: 1])
        try await until { runtime.snapshot()[stories]?.instances.allSatisfy { $0.state == .loaded } == true }
        #expect(Set(runtime.snapshot()[stories]!.instances.map(\.profile)) == [profile, other])
        await runtime.shutdown()
    }

    @Test func eachGenerationGetsTheProfileContext() async throws {
        let runtime = try runtime(.init(maximumActiveGenerations: 2))
        var json = try JSONSerialization.jsonObject(with: chat(maxTokens: 2)) as! [String: Any]
        json["return_context"] = true
        json["stream"] = false
        let generation = try await runtime.generate(model: stories, profile: profile,
                                                    body: try JSONSerialization.data(withJSONObject: json))
        let result = try #require(try await generation.next())
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let context = try #require(object?["context"] as? [String: Any])
        #expect(context["n_ctx"] as? Int == profile.contextSize) // two slots, each with the profile's context
        await runtime.shutdown()
    }

    @Test func fullQueueFailsExplicitly() async throws {
        let runtime = try runtime(.init(maximumActiveGenerations: 1, maximumWaitingRequests: 1))
        // A generation keeps its permit until its end is read.
        let holder = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        let waiting = Task { try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2)) }
        try await until { runtime.snapshot().admission.waitingRequests == 1 }
        #expect(runtime.snapshot().admission.isQueueFull)
        #expect(runtime.snapshot()[stories]?.waitingRequests == 1)
        await #expect(throws: LlamaEngineError.queueFull(waitingCapacity: 1)) {
            _ = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        }
        try await drain(holder) // releases the permit: the waiting request runs
        try await drain(try await waiting.value)
        let admission = runtime.snapshot().admission
        #expect(admission.activeGenerations == 0)
        #expect(admission.waitingRequests == 0)
        await runtime.shutdown()
    }

    @Test func cancellingAWaitingRequestFreesItsPlaceOnce() async throws {
        let runtime = try runtime(.init(maximumActiveGenerations: 1, maximumWaitingRequests: 1))
        let holder = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        let cancelled = Task { try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2)) }
        try await until { runtime.snapshot().admission.waitingRequests == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(runtime.snapshot().admission.waitingRequests == 0)
        #expect(runtime.snapshot().admission.activeGenerations == 1)

        // The freed place takes exactly one request.
        let next = Task { try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2)) }
        try await until { runtime.snapshot().admission.waitingRequests == 1 }
        await #expect(throws: LlamaEngineError.queueFull(waitingCapacity: 1)) {
            _ = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        }
        // Releasing a permit twice does not admit two requests.
        holder.close(.unloaded(stories))
        holder.close(.unloaded(stories))
        let admitted = try await next.value
        #expect(runtime.snapshot().admission.activeGenerations == 1)
        #expect(runtime.snapshot().admission.waitingRequests == 0)
        try await drain(admitted)
        #expect(runtime.snapshot().admission.activeGenerations == 0)
        await runtime.shutdown()
    }

    @Test func admissionWaitIsBounded() async throws {
        let runtime = try runtime(.init(maximumActiveGenerations: 1, maximumWaitingRequests: 2,
                                        admissionTimeout: .milliseconds(200)))
        let holder = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        await #expect(throws: LlamaEngineError.admissionTimedOut(.milliseconds(200))) {
            _ = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        }
        #expect(runtime.snapshot().admission.waitingRequests == 0)
        try await drain(holder)
        await runtime.shutdown()
    }

    @Test func unloadEndsRunningAndWaitingWorkAndKeepsHistories() async throws {
        let runtime = try runtime(.init(maximumActiveGenerations: 1, maximumWaitingRequests: 2))
        // The caller owns the conversation; the runtime never does.
        var history = [["role": "user", "content": "Once upon a time"]]
        let running = try await runtime.generate(model: stories, profile: profile, body: chat(history, maxTokens: -1))
        try await started(running)
        let reader = Task { try await drain(running) }
        let waitingBody = chat(history, maxTokens: 2)
        let waiting = Task { try await runtime.generate(model: stories, profile: profile, body: waitingBody) }
        try await until { runtime.snapshot().admission.waitingRequests == 1 }

        let unloading = Task { try await runtime.unload(stories) }
        await #expect(throws: LlamaEngineError.unloaded(stories)) { _ = try await reader.value }
        await #expect(throws: LlamaEngineError.unloaded(stories)) { _ = try await waiting.value }
        try await unloading.value
        // Returned once the engine freed the instance.
        let model = try #require(runtime.snapshot()[stories])
        #expect(model.availability == .available)
        #expect(model.instances.allSatisfy { $0.state == .unloaded })
        #expect(String(decoding: try runtime.nativeCatalog(), as: UTF8.self).contains("\"unloaded\""))
        #expect(runtime.snapshot().admission.activeGenerations == 0)

        // The history survived; sending it again loads the model again.
        history.append(["role": "assistant", "content": "there was a cat."])
        history.append(["role": "user", "content": "Go on"])
        #expect(try await run(runtime, chat(history, maxTokens: 4)) > 0)
        try await until { runtime.snapshot()[stories]?.isLoaded == true }
        await runtime.shutdown()
    }

    @Test func concurrentLoadsShareOneNativeLoad() async throws {
        let runtime = try runtime()
        let subscription = try runtime.native.subscribe()
        let abandoned = Task { try await runtime.load(stories, profile: profile) }
        async let first: Void = runtime.load(stories, profile: profile)
        async let second: Void = runtime.load(stories, profile: profile)
        abandoned.cancel() // stops this caller's wait only
        try await first
        try await second
        _ = try? await abandoned.value
        #expect(await loads(subscription) == [InstanceKey(model: stories, profile: profile).entryID: 1])
        #expect(runtime.snapshot()[stories]?.isLoaded == true)
        try await runtime.load(stories, profile: profile) // already resident
        await runtime.shutdown()
    }

    @Test func slowSubscriberIsResynchronized() async throws {
        let runtime = try runtime(bufferLimit: 2)
        var updates = runtime.updates().makeAsyncIterator()
        guard case .snapshot(let first) = await updates.next() else {
            Issue.record("the first update is a snapshot")
            return
        }
        #expect(first[stories]?.instances.isEmpty == true)
        // Many changes while the subscriber does not read.
        for _ in 0..<3 {
            try await run(runtime, chat(maxTokens: 2))
        }
        try await runtime.unload(stories)
        var received: [LlamaRuntimeUpdate] = []
        while received.last?.snapshot != runtime.snapshot() {
            received.append(try #require(await updates.next()))
        }
        guard case .resync(let snapshot, let dropped) = received.first else {
            Issue.record("expected a resync, got \(received)")
            return
        }
        #expect(dropped > 0)
        #expect(snapshot[stories] != nil)
        await runtime.shutdown()
        #expect(await updates.next() == nil) // the runtime ended the subscription
    }

    @Test func importCopiesAtomicallyAndRemovalKeepsTheSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source/stories15M-q4_0.gguf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: source)
        let projector = directory.appendingPathComponent("source/mmproj.gguf")
        try fakeGGUF(projector)
        let sourceData = try Data(contentsOf: source)
        let store = try LlamaModelStore(root: directory.appendingPathComponent("store"))
        let runtime = try runtime(store: store)

        let artifact = try await runtime.importModel(LlamaModelImport(id: stories, displayName: "Stories",
                                                                      weights: source, projector: projector))
        #expect(artifact.isManaged)
        #expect(artifact.weights.map(\.lastPathComponent) == ["stories15M-q4_0.gguf"])
        #expect(artifact.projector?.lastPathComponent == "mmproj.gguf")
        let copy = store.directory(of: stories)
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try Data(contentsOf: artifact.weights[0]) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("staging").path).isEmpty)
        #expect(runtime.snapshot()[stories]?.artifact.displayName == "Stories")
        await #expect(throws: LlamaEngineError.modelExists(stories)) {
            _ = try await runtime.importModel(LlamaModelImport(id: stories, weights: source))
        }
        // The catalog survives a new runtime on the same store.
        #expect(try LlamaModelStore(root: store.root).artifacts() == [artifact])

        // The managed copy is usable, then removed during a generation.
        let running = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: -1))
        try await started(running)
        let reader = Task { try await drain(running) }
        try await runtime.removeModel(stories)
        await #expect(throws: LlamaEngineError.modelUnavailable(stories, reason: "removed")) { _ = try await reader.value }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(runtime.snapshot()[stories] == nil)
        #expect(String(decoding: try runtime.nativeCatalog(), as: UTF8.self) == "[]")
        await #expect(throws: LlamaEngineError.modelNotFound(stories)) {
            _ = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 2))
        }
        // The source is untouched.
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(FileManager.default.fileExists(atPath: projector.path))
        await runtime.shutdown()
    }

    @Test func importChecksFilesAndSpace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        // Split model: every announced shard is copied with its name.
        for shard in 1...3 {
            try fakeGGUF(source.appendingPathComponent(String(format: "big-%05d-of-00003.gguf", shard)))
        }
        let store = try LlamaModelStore(root: directory.appendingPathComponent("store"))
        let runtime = try LlamaRuntime(store: store)
        let split = try await runtime.importModel(LlamaModelImport(
            id: LlamaModelID("big"), weights: source.appendingPathComponent("big-00001-of-00003.gguf")))
        #expect(split.weights.map(\.lastPathComponent) == ["big-00001-of-00003.gguf", "big-00002-of-00003.gguf",
                                                           "big-00003-of-00003.gguf"])
        #expect(split.weights.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // A missing shard, a later shard, a file that is not GGUF.
        try FileManager.default.removeItem(at: source.appendingPathComponent("big-00002-of-00003.gguf"))
        for weights in ["big-00001-of-00003.gguf", "big-00003-of-00003.gguf"] {
            await #expect(throws: LlamaEngineError.self) {
                _ = try await runtime.importModel(LlamaModelImport(id: LlamaModelID("broken"),
                                                                   weights: source.appendingPathComponent(weights)))
            }
        }
        let text = source.appendingPathComponent("notes.gguf")
        try Data("not a model".utf8).write(to: text)
        await #expect(throws: LlamaEngineError.invalidModelFile("notes.gguf is not a GGUF file")) {
            _ = try await runtime.importModel(LlamaModelImport(id: LlamaModelID("notes"), weights: text))
        }

        // Not enough space: nothing is copied and the source stays.
        let small = try LlamaModelStore(root: directory.appendingPathComponent("small"), availableCapacity: { _ in 1000 })
        let tight = try LlamaRuntime(store: small)
        let model = source.appendingPathComponent("model.gguf")
        try fakeGGUF(model, bytes: 4096)
        await #expect(throws: LlamaEngineError.insufficientSpace(required: 4100 + LlamaModelStore.reserve, available: 1000)) {
            _ = try await tight.importModel(LlamaModelImport(id: LlamaModelID("model"), weights: model))
        }
        #expect(try small.artifacts().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: small.root.appendingPathComponent("staging").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: model.path))

        // Registered files are the application's: removal never deletes them.
        let bundled = LlamaModelID("bundled")
        try runtime.register(LlamaModelArtifact(id: bundled, weights: [model]))
        try await runtime.removeModel(bundled)
        #expect(FileManager.default.fileExists(atPath: model.path))
        #expect(runtime.snapshot()[bundled] == nil)
        await runtime.shutdown()
        await tight.shutdown()
    }

    @Test func catalogChangesKeepOtherModelsLoaded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LlamaModelStore(root: directory)
        let runtime = try runtime(.init(maximumResidentModels: 2, maximumActiveGenerations: 1), store: store)
        try runtime.register(LlamaModelArtifact(id: stories, weights: [fixture]))
        try await runtime.load(stories, profile: profile)
        let subscription = try runtime.native.subscribe()

        // A generation runs on the loaded model while another model is
        // imported, used, and removed.
        let running = try await runtime.generate(model: stories, profile: profile, body: chat(maxTokens: 24))
        let reader = Task { try await drain(running) }
        let other = LlamaModelID("copy")
        _ = try await runtime.importModel(LlamaModelImport(id: other, weights: fixture))
        try await runtime.load(other, profile: profile)
        try await runtime.removeModel(other)
        #expect(try await reader.value > 0)

        let counts = await loads(subscription)
        #expect(counts[InstanceKey(model: stories, profile: profile).entryID] == nil) // never reloaded
        #expect(counts[InstanceKey(model: other, profile: profile).entryID] == 1)
        #expect(runtime.snapshot()[stories]?.isLoaded == true)
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        await runtime.shutdown()
    }
}
