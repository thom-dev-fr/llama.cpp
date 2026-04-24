import Foundation
import LlamaEngine

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published UI state

    @Published var modelPath: String = "~/Downloads/Qwen3.5-0.8B-Q4_K_M.gguf"
    @Published var systemPrompt: String = "You are a helpful assistant."
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""

    @Published var temperature: Double = 0.7
    @Published var contextSize: Int = 4096
    @Published var gpuLayers: Int = -1
    @Published var flashAttention: Bool = true

    @Published private(set) var engineState: EngineState = .unloaded
    @Published private(set) var isBusy: Bool = false
    @Published var lastError: String?

    // MARK: - Engine

    private let engine = LlamaEngine()
    private var streamTask: Task<Void, Never>?

    init() {
        LlamaEngine.setLogLevel(.info)
    }

    // MARK: - Derived

    var canSend: Bool {
        engineState == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && streamTask == nil
    }

    var canLoad: Bool {
        engineState == .unloaded && !modelPath.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    var canUnload: Bool {
        (engineState == .ready || engineState == .sleeping) && streamTask == nil && !isBusy
    }

    // MARK: - Lifecycle

    func loadModel() {
        let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        lastError = nil
        isBusy = true
        engineState = .loading

        let config = ModelConfig(
            modelPath: URL(fileURLWithPath: path),
            contextSize: Int32(contextSize),
            gpuLayers: Int32(gpuLayers),
            flashAttention: flashAttention
        )

        Task {
            do {
                try await engine.load(config)
                await refreshState()
            } catch {
                lastError = "Load failed: \(error)"
                await refreshState()
            }
            isBusy = false
        }
    }

    func unloadModel() {
        isBusy = true
        Task {
            cancelStream()
            do {
                try await engine.unload()
            } catch {
                lastError = "Unload failed: \(error)"
            }
            await refreshState()
            isBusy = false
        }
    }

    func resetConversation() {
        cancelStream()
        messages.removeAll()
    }

    // MARK: - Chat

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[LlamaChatDemo] send() called — state=\(engineState), streamTask==nil: \(streamTask == nil), promptLen=\(prompt.count)")
        guard !prompt.isEmpty, streamTask == nil else {
            print("[LlamaChatDemo] send() guarded out")
            return
        }

        messages.append(ChatMessage(role: .user, content: prompt))
        draft = ""

        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)

        let requestJSON = buildRequestJSON(stream: true)
        print("[LlamaChatDemo] send() request JSON:", requestJSON)

        streamTask = Task { [engine] in
            defer {
                Task { @MainActor in
                    self.streamTask = nil
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        self.messages[idx].isStreaming = false
                    }
                }
            }

            do {
                let stream = engine.chatCompletionStream(requestJSON: requestJSON)
                var chunkCount = 0
                for try await chunk in stream {
                    chunkCount += 1
                    let delta = Self.extractDelta(from: chunk)
                    if delta.isEmpty { continue }
                    await MainActor.run {
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                            if !delta.reasoning.isEmpty {
                                self.messages[idx].reasoning.append(delta.reasoning)
                            }
                            if !delta.content.isEmpty {
                                self.messages[idx].content.append(delta.content)
                            }
                        }
                    }
                }
                print("[LlamaChatDemo] stream ended, \(chunkCount) chunks")
                if chunkCount == 0 {
                    await MainActor.run {
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                            self.messages[idx].content = "[no chunks received — check console]"
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        if self.messages[idx].content.isEmpty {
                            self.messages[idx].content = "[cancelled]"
                        } else {
                            self.messages[idx].content.append("\n\n[cancelled]")
                        }
                    }
                }
            } catch {
                print("[LlamaChatDemo] stream error:", error)
                await MainActor.run {
                    self.lastError = "\(error)"
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        self.messages[idx].content = "[error: \(error)]"
                    }
                }
            }
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Internals

    private func refreshState() async {
        engineState = await engine.state
    }

    private func buildRequestJSON(stream: Bool) -> String {
        var oaiMessages: [[String: String]] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            oaiMessages.append(["role": "system", "content": sys])
        }
        for m in messages where m.role != .assistant || !m.isStreaming {
            oaiMessages.append(["role": m.role.rawValue, "content": m.content])
        }

        let payload: [String: Any] = [
            "messages": oaiMessages,
            "temperature": temperature,
            "stream": stream,
            // Pour les modèles de raisonnement (DeepSeek-R1, QwQ, …) :
            // sépare le contenu de raisonnement dans `delta.reasoning_content`
            // au lieu de le laisser dans `<think>…</think>` du contenu.
            "reasoning_format": "deepseek",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    struct DeltaParts {
        var content: String = ""
        var reasoning: String = ""
        var isEmpty: Bool { content.isEmpty && reasoning.isEmpty }
    }

    /// Parse un chunk OpenAI-compatible et retourne les deltas `content` et
    /// `reasoning_content` (ce dernier étant présent pour les modèles de
    /// raisonnement quand `reasoning_format=deepseek`).
    ///
    /// Le chunk peut arriver sous deux formes :
    ///  - un objet JSON unique   : `{"choices":[{"delta":{…}}],…}`
    ///  - un tableau d'objets    : `[{"choices":[{"delta":{…}}],…}, …]`
    /// (le deuxième cas est utilisé quand `parallel_slots > 1` ou simplement
    /// par la façon dont server-context agrège certains résultats).
    static func extractDelta(from chunk: String) -> DeltaParts {
        var parts = DeltaParts()
        guard let data = chunk.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else {
            return parts
        }

        let chunkObjects: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            chunkObjects = arr
        } else if let obj = raw as? [String: Any] {
            chunkObjects = [obj]
        } else {
            return parts
        }

        for obj in chunkObjects {
            guard let choices = obj["choices"] as? [[String: Any]] else { continue }
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    if let s = delta["content"] as? String { parts.content += s }
                    if let s = delta["reasoning_content"] as? String { parts.reasoning += s }
                }
                if let message = choice["message"] as? [String: Any] {
                    if let s = message["content"] as? String { parts.content += s }
                    if let s = message["reasoning_content"] as? String { parts.reasoning += s }
                }
            }
        }
        return parts
    }
}
