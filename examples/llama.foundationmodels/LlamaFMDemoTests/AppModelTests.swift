import CryptoKit
import Foundation
@testable import LlamaFMDemo
import LlamaEngine
import LlamaFoundationModels
import Testing

// The application model on the real runtime: settings persistence, model
// selection and conversations, lifecycle, and a background download in an
// application host (the system refuses background sessions to the xctest tool).

/// The small model of the server tests (CPU), from the repository.
private let stories = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/server/tests/tmp/stories15M-q4_0.gguf")
private let hasStories = FileManager.default.fileExists(atPath: stories.path)

/// An isolated application state: its own defaults, store and a foreground
/// session (the host application owns the default background session).
@MainActor
private final class Fixture {
    let suite = "llama-fm-demo-tests-\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    func makeModel() -> AppModel {
        AppModel(defaults: defaults, storeRoot: root, sessionIdentifier: nil)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Suite(.serialized) struct AppModelTests {
    @Test func emptyInstallation() throws {
        let fixture = Fixture()
        let model = fixture.makeModel()
        #expect(model.setupErrors.isEmpty)
        #expect(model.catalog?.models.isEmpty == false)    // the bundled catalog
        #expect(model.installedModels.isEmpty)
        #expect(model.conversations.isEmpty)
        #expect(model.currentConversation == nil)
    }

    @Test func settingsSurviveARelaunch() throws {
        let fixture = Fixture()
        do {
            let model = fixture.makeModel()
            model.settings.contextSize = 2048
            model.settings.greedy = true
            model.settings.tools = false
        }
        let relaunched = fixture.makeModel()
        #expect(relaunched.settings.contextSize == 2048)
        #expect(relaunched.settings.greedy)
        #expect(!relaunched.settings.tools)
        #expect(relaunched.conversations.isEmpty)           // conversations are not restored
    }

    @Test func modelIdentifiersFromNames() {
        #expect(AppModel.modelID(for: "My Model 7B.Q4", existing: []) == LlamaModelID("my-model-7b.q4"))
        #expect(AppModel.modelID(for: "..hidden", existing: []) == LlamaModelID("hidden"))
        #expect(AppModel.modelID(for: "a", existing: [LlamaModelID("a"), LlamaModelID("a-2")]) == LlamaModelID("a-3"))
        #expect(AppModel.modelID(for: "été", existing: []).isValid)
    }

    @Test func backgroundCancelsGenerationsNotInactivity() async throws {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let script = Script([.hang(["a", "b"])])
        let chat = Conversation(modelID: LlamaModelID("scripted"), modelName: "Scripted", profile: nil,
                                model: ScriptedModel(script: script), monitor: nil)
        model.insert(chat)
        chat.send(chat.makeRequest(kind: .chat, text: "x", images: [], settings: model.settings))
        try await until { script.requests.count == 1 }
        model.scenePhaseChanged(from: .active, to: .inactive)  // a file picker, the app switcher
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.isResponding)
        model.scenePhaseChanged(from: .inactive, to: .background)
        await chat.waitUntilIdle()
        #expect(chat.turns.last?.status == .interrupted(.init(isCancellation: true, message: LifecyclePolicy.backgroundReason)))
        #expect(chat.transcript.exchanges.isEmpty)        // back to the last complete turn
    }

    /// From an empty store: a registered model, a streamed answer on the real
    /// engine, the indicators, unload during a generation, a model change.
    @Test(.enabled(if: hasStories, "needs tools/server/tests/tmp/stories15M-q4_0.gguf"))
    func endToEndWithTheEngine() async throws {
        let fixture = Fixture()
        let model = fixture.makeModel()
        model.settings.usesGPU = false
        model.settings.contextSize = 2048
        // stories15M was trained on 128 tokens: the engine caps the context of
        // the instance there, whatever the profile asks (effective capacity).
        model.settings.maximumResponseTokens = 8
        let runtime = try #require(model.runtime)
        try runtime.register(LlamaModelArtifact(id: LlamaModelID("stories"), displayName: "Stories", weights: [stories]))
        try await until { model.installed(LlamaModelID("stories")) != nil }

        // the first model is selected and gets a conversation
        let chat = try #require(model.currentConversation)
        #expect(chat.modelID == LlamaModelID("stories"))
        #expect(!chat.capabilities.contains(.toolCalling))   // registered: nothing qualified
        #expect(ContextGauge(chat.monitorState).value == .unavailable)

        // the generation loads the model on demand
        chat.send(chat.makeRequest(kind: .chat, text: "Once upon a time", images: [], settings: model.settings))
        await chat.waitUntilIdle()
        let turn = try #require(chat.turns.last)
        #expect(turn.status == .complete, "\(turn.status)")
        #expect(!turn.text.isEmpty)
        #expect(chat.transcript.exchanges.count == 2)
        try await until { chat.monitorState.phase == .idle }
        let gauge = ContextGauge(chat.monitorState)
        guard case .measured(let occupied, let capacity) = gauge.value else {
            Issue.record("no context measure")
            return
        }
        #expect(capacity == 128)
        #expect(occupied > 0)
        #expect(!gauge.isLive)                                // the last measure, marked as such
        try await until { model.installed(chat.modelID)?.isLoaded == true }

        // the instructions and one exchange nearly fill 128 tokens: a second
        // conversation with the same model (and its loaded instance)
        model.startConversation()
        let second = try #require(model.currentConversation)
        #expect(second.id != chat.id && second.profile == chat.profile)
        #expect(model.conversations.count == 2)

        // unloading ends the running request; the history stays
        var next = model.settings
        next.maximumResponseTokens = 12
        second.send(second.makeRequest(kind: .chat, text: "Tell", images: [], settings: next))
        model.unload(second.modelID)                          // while the request waits or runs
        await second.waitUntilIdle()
        let unloadedFirst = second.turns.last?.isInterrupted == true
        if case .interrupted(let interruption)? = second.turns.last?.status {
            // ended by the unload, or refused while the unload closes the admissions
            #expect(interruption.message.contains("unloaded") || interruption.message.contains("unavailable"),
                    "\(interruption)")
            print("demo e2e: interrupted: \(interruption.message)")
            #expect(second.transcript.exchanges.isEmpty)
        } else {
            print("demo e2e: the answer ended before the unload")  // 12 tokens on the CPU: a race
            #expect(second.turns.last?.status == .complete)
        }
        try await until { model.installed(chat.modelID)?.isLoaded == false && !model.running.contains(.unload(chat.modelID)) }
        #expect(chat.transcript.exchanges.count == 2)          // the other conversation keeps its history

        // another model: a new conversation, the old one stays available
        try runtime.register(LlamaModelArtifact(id: LlamaModelID("stories-copy"), displayName: "Stories copy",
                                                weights: [stories]))
        try await until { model.installed(LlamaModelID("stories-copy")) != nil }
        model.selectModel(LlamaModelID("stories-copy"))
        #expect(model.conversations.count == 3)
        #expect(model.currentConversation?.modelID == LlamaModelID("stories-copy"))
        #expect(model.conversations.contains { $0.id == chat.id && $0.turns.count == 1 })
        #expect(model.conversations.contains { $0.id == second.id && $0.turns.count == 1 })

        // retry the interrupted turn: the model loads again
        if unloadedFirst {
            print("demo e2e: unloaded during the request, retrying")
            second.retry()
            await second.waitUntilIdle()
            #expect(second.turns.last?.status == .complete, "\(String(describing: second.turns.last?.status))")
            #expect(second.transcript.exchanges.count == 2)
        }
        await runtime.shutdown()
    }

    /// The P4 scenario that needs an application: a background URLSession
    /// transfers a catalog entry from a local server and installs it.
    @Test(.timeLimit(.minutes(2)))
    func backgroundSessionDownloadInstalls() async throws {
        let server = try TestHTTPServer()
        let base = try await server.start()
        defer { server.stop() }
        let revision = "0123456789abcdef0123456789abcdef01234567"
        var weights = Data("GGUF".utf8)
        weights.append(contentsOf: (0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        server["/\(revision)/tiny.gguf"] = .init(data: weights, etag: "\"w1\"")
        let digest = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        let entry = LlamaModelCatalog.Entry(
            id: LlamaModelID("tiny"), displayName: "Tiny", source: .init(repository: "127.0.0.1/tiny", revision: revision),
            weights: [.init(name: "tiny.gguf", url: base.appendingPathComponent("\(revision)/tiny.gguf"),
                            size: Int64(weights.count), sha256: digest)],
            license: .init(identifier: "mit"), chatTemplate: .init(source: "chatml"), declaredCapabilities: [])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try LlamaRuntime(store: LlamaModelStore(root: root))
        let downloads = try LlamaModelDownloads(
            runtime: runtime, configuration: .init(sessionIdentifier: "org.ggml.llama.demo-tests.\(UUID().uuidString)"))
        defer { downloads.invalidate() }
        #expect(downloads.sessionIdentifier != nil)
        try await Task.sleep(for: .milliseconds(200))       // reattachment of a previous launch (none)
        try downloads.start(entry)
        try await until(.seconds(90)) { runtime.snapshot()[entry.id] != nil }
        #expect(runtime.snapshot()[entry.id]?.artifact.catalogEntry == entry)
        try await until { downloads.snapshot()[entry.id] == nil }
        #expect(!server.requests(for: "/\(revision)/tiny.gguf").isEmpty)
    }
}
