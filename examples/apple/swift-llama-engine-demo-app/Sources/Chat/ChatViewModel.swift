import Foundation
import Observation
import LlamaEngine

@MainActor
@Observable
final class ChatViewModel {

    // MARK: - UI state

    var modelPath: String = ""
    /// Optional path to a multimodal projector (mmproj GGUF).
    var mmprojPath: String = ""
    var systemPrompt: String = "You are a helpful assistant. When the user asks for the current time or a calculation, call the appropriate tool."
    var messages: [ChatMessage] = []
    var draft: String = ""
    /// Attachments waiting to be sent with the next user message.
    var pendingAttachments: [ChatMessage.Attachment] = []

    var temperature: Double = 0.7
    var contextSize: Int = 4096
    var gpuLayers: Int = -1
    var flashAttention: Bool = true

    /// Exposes the functions declared in `ToolRegistry` to the model.
    var enableTools: Bool = true

    private(set) var engineState: EngineState = .unloaded
    private(set) var modelInfo: ModelInfo? = nil
    var lastError: String?

    // MARK: - Engine

    @ObservationIgnored private let engine = LlamaEngine()
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    /// Guard against models repeatedly calling the same tools.
    private let maxToolHops = 4

    init() {
        LlamaEngine.setLogLevel(.info)
    }

    // MARK: - Derived

    /// Capability flags of the currently loaded model, or all-false when no
    /// model is loaded. Convenience for the view layer.
    var capabilities: ModelCapabilities {
        modelInfo?.capabilities ?? ModelCapabilities()
    }

    var canSend: Bool {
        guard engineState == .ready, streamTask == nil else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingAttachments.isEmpty
    }

    var isStreaming: Bool {
        messages.last?.isStreaming == true
    }

    var canLoad: Bool {
        engineState == .unloaded
            && !modelPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canUnload: Bool {
        engineState == .ready || engineState == .paused
    }

    /// Pause is allowed while the engine owns or is preparing a context.
    var canPause: Bool {
        engineState == .ready || engineState == .loading || engineState == .resuming
    }

    var canResume: Bool {
        engineState == .paused
    }

    // MARK: - Lifecycle

    func loadModel() {
        let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        lastError = nil
        engineState = .loading

        let mmproj = mmprojPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelURL  = URL(fileURLWithPath: path)
        let mmprojURL: URL? = mmproj.isEmpty ? nil : URL(fileURLWithPath: mmproj)

        let config = ModelConfig(
            modelPath: modelURL,
            contextSize: Int32(contextSize),
            gpuLayers: Int32(gpuLayers),
            mtmdProjectorPath: mmprojURL,
            flashAttention: flashAttention
        )

        Task {
            // Probe the model file *before* loading. Cheap (metadata only)
            // and gives us the capabilities the UI needs to gate features.
            do {
                modelInfo = try await LlamaEngine.modelInfo(modelURL: modelURL,
                                                            mmprojURL: mmprojURL)
            } catch {
                // Soft failure: continue with empty info; load() will produce
                // the canonical error if the file is really broken.
                modelInfo = nil
            }

            do {
                try await engine.load(config)
            } catch LlamaError.cancelled {
                // pause() preempted the load; this is not an error.
            } catch {
                lastError = "Load failed: \(error)"
            }
            await refreshState()
        }
    }

    func unloadModel() {
        cancelStream()
        engineState = .unloading
        Task {
            do {
                try await engine.unload()
            } catch {
                lastError = "Unload failed: \(error)"
            }
            modelInfo = nil
            await refreshState()
        }
    }

    /// Preemptively pauses the engine and updates UI state immediately.
    func pauseModel() {
        guard canPause else { return }
        cancelStream()
        lastError = nil
        engineState = .pausing

        let engineRef = engine
        Task.detached { [weak self] in
            let failure: Error?
            do {
                try await engineRef.pause()
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run { [weak self] in
                if let err = failure {
                    self?.lastError = "Pause failed: \(err)"
                }
            }
            await self?.refreshState()
        }
    }

    /// Reloads the paused context using the cached engine configuration.
    func resumeModel() {
        guard canResume else { return }
        lastError = nil
        engineState = .resuming
        Task {
            do {
                try await engine.resume()
            } catch LlamaError.cancelled {
                // pause() preempted resume; the final state remains paused.
            } catch {
                lastError = "Resume failed: \(error)"
            }
            await refreshState()
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

    /// Starts an assistant stream and follows tool calls for a bounded number of hops.
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
                let stream = try await engine.chatCompletionStream(requestJSON: requestJSON)
                var chunkCount = 0
                for try await chunk in stream {
                    chunkCount += 1
                    let parsed = ChatCompletionStreamParser.parse(chunk)

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
                        // Mirror partial tool calls so the UI can show them while streaming.
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

            // Execute collected tool calls, then ask the model for the final answer.
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

        // Continue with the tool results now present in the conversation.
        launchCompletion(hopsRemaining: hopsRemaining - 1)
    }

    // MARK: - Request building

    private func buildRequestJSON(stream: Bool) -> String {
        ChatRequestBuilder(
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            enableTools: enableTools
        ).build(stream: stream)
    }

    // MARK: - Internals

    private func refreshState() async {
        engineState = engine.state
    }

    // MARK: - Attachments

    /// Adds an attachment only when the loaded model supports its modality.
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

    /// Adds an image selected by the UI.
    func addImage(fromURL url: URL) {
        guard capabilities.supportsVision else { return }
        // Required for sandboxed file importers.
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        if let a = AttachmentSupport.makeImageAttachment(from: url) {
            addAttachment(a)
        } else {
            lastError = "Unable to read image at \(url.lastPathComponent)."
        }
    }

    /// Adds a .wav or .mp3 file selected by the UI.
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
