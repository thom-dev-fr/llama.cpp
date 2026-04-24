import Foundation
import LlamaEngine

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published UI state

    @Published var modelPath: String = ""
    /// Chemin optionnel vers un projector multimodal (mmproj GGUF).
    /// Laisser vide pour un modèle texte.
    @Published var mmprojPath: String = ""
    @Published var systemPrompt: String = "You are a helpful assistant. When the user asks for the current time or a calculation, call the appropriate tool."
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    /// Pièces jointes en attente d'envoi avec le prochain message user.
    @Published var pendingAttachments: [ChatMessage.Attachment] = []

    @Published var temperature: Double = 0.7
    @Published var contextSize: Int = 4096
    @Published var gpuLayers: Int = -1
    @Published var flashAttention: Bool = true

    /// Expose les fonctions déclarées dans `ToolRegistry` au modèle.
    @Published var enableTools: Bool = true

    @Published private(set) var engineState: EngineState = .unloaded
    @Published private(set) var capabilities: EngineCapabilities = .none
    @Published private(set) var isBusy: Bool = false
    /// True entre le clic Sleep et l'exécution effective côté moteur.
    /// Sert aussi à distinguer une demande "sleep pendant loading" en file d'attente.
    @Published private(set) var pendingSleep: Bool = false
    /// Idem pour wake : l'UI affiche un état transitoire pendant le re-load.
    @Published private(set) var pendingWake: Bool = false
    @Published var lastError: String?

    // MARK: - Engine

    private let engine = LlamaEngine()
    private var streamTask: Task<Void, Never>?

    /// Garde-fou contre une boucle infinie de tool calls (modèle qui
    /// rappellerait sans cesse les mêmes tools).
    private let maxToolHops = 4

    init() {
        LlamaEngine.setLogLevel(.info)
    }

    // MARK: - Derived

    var canSend: Bool {
        guard engineState == .ready, streamTask == nil else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingAttachments.isEmpty
    }

    var canLoad: Bool {
        engineState == .unloaded
            && !modelPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !isBusy
    }

    var canUnload: Bool {
        (engineState == .ready || engineState == .sleeping)
            && !isBusy
    }

    /// On autorise Sleep à tout moment où le moteur détient (ou prépare) un
    /// contexte : `.ready`, `.loading` (load initial en cours) ou pendant un
    /// wake en cours (toujours `.loading` côté C++). La méthode `sleep()`
    /// étant `nonisolated`, elle préempte activement le chargement via le
    /// progress-callback de llama.cpp — usage typique iOS-background.
    var canSleep: Bool {
        (engineState == .ready || engineState == .loading)
            && !pendingSleep
    }

    var canWake: Bool {
        engineState == .sleeping && !pendingWake && !isBusy
    }

    // MARK: - Lifecycle

    func loadModel() {
        let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        lastError = nil
        isBusy = true
        engineState = .loading

        let mmproj = mmprojPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ModelConfig(
            modelPath: URL(fileURLWithPath: path),
            contextSize: Int32(contextSize),
            gpuLayers: Int32(gpuLayers),
            mtmdProjectorPath: mmproj.isEmpty ? nil : URL(fileURLWithPath: mmproj),
            flashAttention: flashAttention
        )

        Task {
            do {
                try await engine.load(config)
            } catch LlamaError.cancelled {
                // Le load a été préempté par sleep() — pas une vraie erreur.
            } catch {
                lastError = "Load failed: \(error)"
            }
            await refreshState()
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

    /// Mise en veille préemptive. Peut être appelée à n'importe quel moment :
    ///  - depuis `.ready` : teardown normal.
    ///  - pendant un `load()` ou `wake()` en cours : le progress-callback
    ///    côté llama.cpp interrompt le chargement, puis le C-core bascule
    ///    directement en `.sleeping` en conservant `last_params` pour un
    ///    futur `wake()`. C'est le cas d'usage iOS → background.
    ///
    /// L'appel C `llama_engine_sleep` est synchrone et attend que le
    /// chargement se soit effectivement arrêté (quelques ms au plus après le
    /// prochain callback de progression, soit ~1% de données chargées). On
    /// l'exécute dans une `Task.detached` pour ne pas bloquer le main thread.
    func sleepModel() {
        guard canSleep else { return }
        cancelStream()
        lastError = nil
        pendingSleep = true

        let engineRef = engine
        Task.detached { [weak self] in
            let failure: Error? = {
                do {
                    try engineRef.sleep()
                    return nil
                } catch {
                    return error
                }
            }()
            await MainActor.run { [weak self] in
                if let err = failure {
                    self?.lastError = "Sleep failed: \(err)"
                }
                self?.pendingSleep = false
            }
            await self?.refreshState()
        }
    }

    /// Ré-hydrate le contexte depuis l'état `.sleeping`. Déclenche un nouveau
    /// chargement du modèle avec les mêmes `last_params` conservés côté C++.
    /// Peut lui-même être préempté par un `sleepModel()` — dans ce cas l'appel
    /// throw `.cancelled` qu'on ignore silencieusement.
    func wakeModel() {
        guard canWake else { return }
        lastError = nil
        pendingWake = true
        Task {
            do {
                try await engine.wake()
            } catch LlamaError.cancelled {
                // Wake préempté par sleep() — état final = .sleeping, rien à faire.
            } catch {
                lastError = "Wake failed: \(error)"
            }
            await refreshState()
            pendingWake = false
        }
    }

    func resetConversation() {
        cancelStream()
        messages.removeAll()
    }

    // MARK: - Chat

    func send() {
        guard streamTask == nil else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        var msg = ChatMessage(role: .user, content: prompt)
        msg.attachments = attachments
        messages.append(msg)

        draft = ""
        pendingAttachments.removeAll()

        launchCompletion(hopsRemaining: maxToolHops)
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Completion loop (supports multi-hop tool calls)

    /// Crée une nouvelle bulle assistant puis lance un stream vers le moteur.
    /// Si le modèle répond par des tool calls, ceux-ci sont exécutés et la
    /// fonction se rappelle récursivement avec `hopsRemaining - 1`.
    private func launchCompletion(hopsRemaining: Int) {
        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)

        let requestJSON = buildRequestJSON(stream: true)

        streamTask = Task { [engine] in
            defer {
                Task { @MainActor in
                    self.streamTask = nil
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        self.messages[idx].isStreaming = false
                    }
                }
            }

            var toolCallAccumulators: [Int: ChatMessage.ToolCall] = [:]
            var finishReason: String? = nil

            do {
                let stream = engine.chatCompletionStream(requestJSON: requestJSON)
                var chunkCount = 0
                for try await chunk in stream {
                    chunkCount += 1
                    let parsed = Self.parseChunk(chunk)

                    if let reason = parsed.finishReason {
                        finishReason = reason
                    }

                    for tcDelta in parsed.toolCallDeltas {
                        var acc = toolCallAccumulators[tcDelta.index]
                            ?? ChatMessage.ToolCall(id: "", name: "", arguments: "")
                        if let id = tcDelta.id,   !id.isEmpty   { acc.id = id }
                        if let n  = tcDelta.name, !n.isEmpty    { acc.name = n }
                        acc.arguments += tcDelta.argumentsDelta
                        toolCallAccumulators[tcDelta.index] = acc
                    }

                    if parsed.content.isEmpty && parsed.reasoning.isEmpty && parsed.toolCallDeltas.isEmpty {
                        continue
                    }

                    await MainActor.run {
                        guard let idx = self.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                        if !parsed.reasoning.isEmpty {
                            self.messages[idx].reasoning.append(parsed.reasoning)
                        }
                        if !parsed.content.isEmpty {
                            self.messages[idx].content.append(parsed.content)
                        }
                        // Mirror de l'état courant des tool calls dans le message
                        // pour que l'UI puisse les afficher dès l'ouverture.
                        let sorted = toolCallAccumulators.keys.sorted().compactMap { toolCallAccumulators[$0] }
                        self.messages[idx].toolCalls = sorted
                    }
                }
                print("[LlamaChatDemo] stream ended, \(chunkCount) chunks, finish=\(finishReason ?? "nil"), toolCalls=\(toolCallAccumulators.count)")

                if chunkCount == 0 {
                    await MainActor.run {
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                            self.messages[idx].content = "[no chunks received — check console]"
                        }
                    }
                    return
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
                return
            } catch {
                print("[LlamaChatDemo] stream error:", error)
                await MainActor.run {
                    self.lastError = "\(error)"
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        self.messages[idx].content = "[error: \(error)]"
                    }
                }
                return
            }

            // Stream terminé. S'il y a des tool calls à exécuter, on le fait
            // sur le MainActor puis on relance une complétion.
            let collected = toolCallAccumulators.keys.sorted().compactMap { toolCallAccumulators[$0] }
            if !collected.isEmpty {
                await MainActor.run {
                    self.handleToolCalls(collected, hopsRemaining: hopsRemaining)
                }
            }
        }
    }

    private func handleToolCalls(_ calls: [ChatMessage.ToolCall], hopsRemaining: Int) {
        guard hopsRemaining > 0 else {
            lastError = "Tool-call loop limit reached (\(maxToolHops) hops)."
            return
        }

        for call in calls {
            let result: String
            if let tool = ToolRegistry.find(call.name) {
                print("[LlamaChatDemo] executing tool \(call.name)(\(call.arguments))")
                result = tool.execute(call.arguments)
            } else {
                result = "{\"error\":\"unknown tool '\(call.name)'\"}"
            }

            var msg = ChatMessage(role: .tool, content: result)
            msg.toolCallID = call.id
            msg.toolName   = call.name
            messages.append(msg)
        }

        // Relance une complétion pour que le modèle produise la réponse finale
        // à partir des résultats de tools qu'on vient d'ajouter.
        launchCompletion(hopsRemaining: hopsRemaining - 1)
    }

    // MARK: - Request building

    private func buildRequestJSON(stream: Bool) -> String {
        var oaiMessages: [[String: Any]] = []

        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            oaiMessages.append(["role": "system", "content": sys])
        }

        for m in messages {
            if m.role == .assistant && m.isStreaming { continue }
            switch m.role {
            case .system:
                continue // déjà injecté une seule fois ci-dessus
            case .user:
                oaiMessages.append(["role": "user", "content": userContent(for: m)])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant"]
                // OAI autorise `content` vide quand il y a des tool_calls.
                entry["content"] = m.content
                if m.hasToolCalls {
                    entry["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                        [
                            "id":   tc.id,
                            "type": "function",
                            "function": [
                                "name":      tc.name,
                                "arguments": tc.arguments,
                            ],
                        ]
                    }
                }
                oaiMessages.append(entry)
            case .tool:
                oaiMessages.append([
                    "role":         "tool",
                    "tool_call_id": m.toolCallID ?? "",
                    "name":         m.toolName ?? "",
                    "content":      m.content,
                ])
            }
        }

        var payload: [String: Any] = [
            "messages":         oaiMessages,
            "temperature":      temperature,
            "stream":           stream,
            "reasoning_format": "deepseek",
        ]
        if enableTools {
            payload["tools"]       = ToolRegistry.oaiToolsArray()
            payload["tool_choice"] = "auto"
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Construit le champ `content` d'un message user au format OAI.
    /// Renvoie une simple `String` si aucune pièce jointe, sinon un tableau
    /// de parts multimodales (text / image_url / input_audio).
    private func userContent(for m: ChatMessage) -> Any {
        guard m.hasAttachments else {
            return m.content
        }
        var parts: [[String: Any]] = []
        if !m.content.isEmpty {
            parts.append(["type": "text", "text": m.content])
        }
        for a in m.attachments {
            switch a.kind {
            case .image(let mime):
                let b64 = a.data.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(b64)"],
                ])
            case .audio(let format):
                parts.append([
                    "type": "input_audio",
                    "input_audio": [
                        "data":   a.data.base64EncodedString(),
                        "format": format,
                    ],
                ])
            }
        }
        return parts
    }

    // MARK: - Chunk parsing

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

    /// Parse un chunk streaming OAI. Le moteur peut renvoyer :
    ///  - un objet JSON unique   : `{"choices":[{"delta":{…}}],…}`
    ///  - un tableau d'objets    : `[{"choices":[…]}, …]`
    static func parseChunk(_ chunk: String) -> ChunkParts {
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
                        delta.id   = tc["id"]   as? String
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

    // MARK: - Internals

    private func refreshState() async {
        engineState  = engine.state
        capabilities = await engine.capabilities
    }

    // MARK: - Attachments

    /// Ajoute une pièce jointe à la composition en cours. Refuse silencieusement
    /// si le modèle courant ne supporte pas la modalité concernée.
    func addAttachment(_ attachment: ChatMessage.Attachment) {
        switch attachment.kind {
        case .image where !capabilities.supportsVision: return
        case .audio where !capabilities.supportsAudio:  return
        default: break
        }
        pendingAttachments.append(attachment)
    }

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Appelé par l'UI quand l'utilisateur pointe un fichier image.
    func addImage(fromURL url: URL) {
        guard capabilities.supportsVision else { return }
        // Security-scoped resource sur macOS sandboxé et iOS file importer.
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        if let a = AttachmentSupport.makeImageAttachment(from: url) {
            addAttachment(a)
        } else {
            lastError = "Unable to read image at \(url.lastPathComponent)."
        }
    }

    /// Appelé par l'UI quand l'utilisateur pointe un fichier audio .wav/.mp3.
    func addAudio(fromURL url: URL) {
        guard capabilities.supportsAudio else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        if let a = AttachmentSupport.makeAudioAttachment(from: url) {
            addAttachment(a)
        } else {
            lastError = "Audio must be .wav or .mp3 and ≤ 20 MB."
        }
    }
}
