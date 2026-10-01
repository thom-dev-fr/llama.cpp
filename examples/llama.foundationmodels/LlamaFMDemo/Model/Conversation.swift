import Foundation
import FoundationModels
import LlamaEngine
import LlamaFoundationModels
import Observation

/// One conversation with one model: a `LanguageModelSession` (which owns the
/// transcript and runs the tools) and the turns as displayed.
///
/// A conversation keeps its model and load profile; choosing another model
/// starts a new conversation. Conversations live in memory only.
@MainActor @Observable
final class Conversation: Identifiable {
    let id = UUID()
    let modelID: LlamaModelID
    let modelName: String
    /// Nil for a model that is not a llama.cpp model (tests).
    let profile: LlamaLoadProfile?
    let capabilities: LanguageModelCapabilities
    let startedAt = Date()

    private(set) var turns: [Turn] = []
    private(set) var isResponding = false
    /// Phase, prompt progress and context occupancy of the requests.
    private(set) var monitorState = LlamaGenerationMonitor.State.initial
    let hasMonitor: Bool
    /// Why images are refused, for a model without vision.
    let visionUnavailableReason: String

    @ObservationIgnored private let session: LanguageModelSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellationReason: String?
    @ObservationIgnored private let observation = TaskBox()

    static let instructions = """
        You are a helpful and concise assistant running on the user's device. \
        When tools are available, use them for arithmetic and for questions about the shop's products.
        """

    init(modelID: LlamaModelID, modelName: String, profile: LlamaLoadProfile?, model: some LanguageModel,
         monitor: LlamaGenerationMonitor?, tools: [any Tool] = [CalculatorTool(), ProductLookupTool()],
         visionUnavailableReason: String? = nil) {
        self.modelID = modelID
        self.modelName = modelName
        self.profile = profile
        capabilities = model.capabilities
        hasMonitor = monitor != nil
        self.visionUnavailableReason = visionUnavailableReason ?? "\(modelName) has no qualified image input."
        // Tools are declared only to a model that calls tools: the adapter
        // refuses a request with tools for a model without the capability.
        session = LanguageModelSession(model: model, tools: model.capabilities.contains(.toolCalling) ? tools : [],
                                       instructions: Self.instructions)
        if let monitor {
            observation.task = Task { [weak self] in
                for await state in monitor.updates() {
                    self?.monitorState = state
                }
            }
        }
    }

    /// The authoritative transcript (Foundation Models'): complete turns only.
    var transcript: Transcript { session.transcript }

    /// Cumulated consumption of the session. Never an occupancy of the context.
    var usage: LanguageModelSession.Usage { session.usage }

    var title: String {
        turns.first.map { $0.request.text.isEmpty ? "Image" : $0.request.text } ?? "New conversation"
    }

    // MARK: Requests

    /// The request for `text` with the current settings, translated for what
    /// this conversation's model declares.
    func makeRequest(kind: TurnRequest.Kind, text: String, images: [PromptImage], settings: DemoSettings) -> TurnRequest {
        let toolsOffered = capabilities.contains(.toolCalling)
        let options = GenerationOptions(samplingMode: settings.greedy ? .greedy : nil,
                                        maximumResponseTokens: settings.maximumResponseTokens,
                                        toolCallingMode: toolsOffered ? (settings.tools ? .allowed : .disallowed) : nil)
        // Only a model that reasons gets a reasoning level. With Qwen3.5-2B,
        // reasoning with the schema in the prompt often loops on the schema
        // (P5 report): a structured answer that reasons gets the schema from
        // the grammar only.
        let reasons = capabilities.contains(.reasoning) && settings.reasoning
        let reasoningLevel: ContextOptions.ReasoningLevel? =
            capabilities.contains(.reasoning) ? (reasons ? nil : .custom("none")) : nil
        let contextOptions = ContextOptions(includeSchemaInPrompt: kind == .cityGuide ? !reasons : nil,
                                            reasoningLevel: reasoningLevel)
        return TurnRequest(kind: kind, text: text, images: images, options: options, contextOptions: contextOptions)
    }

    /// Why an action is not possible with this conversation's model, or nil.
    func refusal(images: [PromptImage]) -> String? {
        if !images.isEmpty, !capabilities.contains(.vision) {
            return visionUnavailableReason
        }
        return nil
    }

    /// Starts a turn; false while another one runs.
    @discardableResult
    func send(_ request: TurnRequest) -> Bool {
        guard !isResponding else { return false }
        let turn = Turn(request: request)
        turns.append(turn)
        isResponding = true
        cancellationReason = nil
        let id = turn.id
        task = Task { [weak self] in
            await self?.run(id)
        }
        return true
    }

    /// Cancels the running turn; its fragments stay, marked interrupted.
    func cancel(reason: String = "Stopped") {
        guard let task else { return }
        if cancellationReason == nil {
            cancellationReason = reason
        }
        task.cancel()
    }

    /// The last turn was interrupted and nothing runs.
    var canRetry: Bool {
        !isResponding && turns.last?.isInterrupted == true
    }

    /// Submits the interrupted request once more. The session already went
    /// back to the last complete turn: nothing of the interrupted one is sent.
    func retry() {
        guard canRetry, let last = turns.last else { return }
        send(last.request)
    }

    /// Waits for the running turn to end (tests).
    func waitUntilIdle() async {
        await task?.value
    }

    private func run(_ id: Turn.ID) async {
        guard let request = turns.first(where: { $0.id == id })?.request else { return }
        let prompt = request.prompt
        let completeEntries = session.transcript.count
        do {
            switch request.kind {
            case .chat:
                let stream = session.streamResponse(options: request.options, contextOptions: request.contextOptions) {
                    prompt
                }
                for try await snapshot in stream {
                    update(id) {
                        $0.apply(snapshot.transcriptEntries)
                        $0.text = snapshot.content
                        $0.usage = Turn.Usage(snapshot.usage)
                    }
                }
            case .cityGuide:
                let stream = session.streamResponse(generating: CityGuide.self, options: request.options,
                                                    contextOptions: request.contextOptions) {
                    prompt
                }
                for try await snapshot in stream {
                    update(id) {
                        $0.apply(snapshot.transcriptEntries)
                        $0.guide = snapshot.content
                        $0.usage = Turn.Usage(snapshot.usage)
                    }
                }
            }
            // A cancelled stream ends without an error (observed, iOS 27.0).
            try Task.checkCancellation()
            update(id) { $0.status = .complete }
        } catch {
            await rollBack(to: completeEntries)
            let interruption = Self.interruption(error, cancellationReason: cancellationReason)
            update(id) { $0.status = .interrupted(interruption) }
        }
        task = nil
        isResponding = false
    }

    /// Brings the transcript back to the last complete turn. Foundation Models
    /// reverts a turn that failed, but keeps the partial response of a
    /// cancelled stream (observed, iOS 27.0); the demo keeps such fragments in
    /// the turn only.
    private func rollBack(to count: Int) async {
        // the session may still be finishing the cancelled request
        for _ in 0..<1000 where session.isResponding {
            await Task.yield()
        }
        guard !session.isResponding, session.transcript.count > count else { return }
        session.transcript.removeSubrange(count...)
    }

    private func update(_ id: Turn.ID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    static func interruption(_ error: any Error, cancellationReason: String?) -> Turn.Interruption {
        if let cancellationReason {
            return Turn.Interruption(isCancellation: true, message: cancellationReason)
        }
        if error is CancellationError {
            return Turn.Interruption(isCancellation: true, message: "Cancelled")
        }
        let presentation = ErrorPresentation(error)
        return Turn.Interruption(isCancellation: false, message: presentation.message, detail: presentation.detail)
    }
}

/// A user-facing message for an error, with the diagnostic kept apart.
struct ErrorPresentation: Equatable {
    var message: String
    var detail: String?

    init(message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    init(_ error: any Error) {
        switch error {
        case LanguageModelError.contextSizeExceeded(let info):
            self.init(message: "The conversation does not fit in the context: \(info.tokenCount) tokens needed, "
                + "\(info.contextSize) available. Start a new conversation, or a larger context in Settings.",
                      detail: info.debugDescription)
        case LanguageModelError.unsupportedCapability(let info):
            self.init(message: "This model does not support \(Self.name(info.capability)) for this request.",
                      detail: info.debugDescription)
        case LanguageModelError.unsupportedGenerationGuide(let info):
            self.init(message: "A constraint of \(info.schemaName ?? "the schema") is not supported by the engine.",
                      detail: info.debugDescription)
        case LanguageModelError.unsupportedTranscriptContent(let info):
            self.init(message: "The conversation contains content this model cannot read.", detail: info.debugDescription)
        case let error as LlamaEngineError:
            self.init(message: error.localizedDescription, detail: Self.detail(error))
        case let error as LocalizedError:
            let message = error.errorDescription ?? String(describing: error)
            let detail = String(reflecting: error)
            self.init(message: message, detail: detail == message ? nil : detail)
        default:
            self.init(message: error.localizedDescription, detail: String(describing: error))
        }
    }

    static func name(_ capability: LanguageModelCapabilities.Capability) -> String {
        switch capability {
        case .vision: "image input"
        case .toolCalling: "tool calling"
        case .reasoning: "this reasoning level"
        case .guidedGeneration: "guided generation"
        default: "a capability"
        }
    }

    private static func detail(_ error: LlamaEngineError) -> String? {
        if case .native(let category, _, let details) = error {
            return "\(category) \(String(decoding: details, as: UTF8.self))"
        }
        return nil
    }
}

/// Cancels its task when released (owners isolated to an actor cannot touch
/// their properties in `deinit`).
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    var task: Task<Void, Never>? {
        get { lock.withLock { tasks.last } }
        set { lock.withLock { if let newValue { tasks.append(newValue) } } }
    }

    deinit {
        for task in tasks { task.cancel() }
    }
}
