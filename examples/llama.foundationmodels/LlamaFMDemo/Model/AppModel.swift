import Foundation
import FoundationModels
import LlamaEngine
import LlamaFoundationModels
import Observation
import SwiftUI

/// The application's state: one shared runtime with its model store, the
/// downloads, the bundled catalog, the settings and the conversations.
///
/// Long operations (download, import, load, unload, removal, generation) run
/// in tasks and report through observable state; none blocks the interface.
@MainActor @Observable
final class AppModel {
    /// An action of the library, to show its progress and errors where it was asked.
    enum Action: Hashable {
        case download(LlamaModelID)
        case load(LlamaModelID)
        case unload(LlamaModelID)
        case remove(LlamaModelID)
        case importModel
    }

    let runtime: LlamaRuntime?
    let downloads: LlamaModelDownloads?
    /// The models offered for download (the package's qualified catalog).
    let catalog: LlamaModelCatalog?
    /// Why the runtime or the catalog could not be set up.
    let setupErrors: [String]

    private(set) var runtimeSnapshot: LlamaRuntimeSnapshot?
    private(set) var downloadsSnapshot: LlamaDownloadsSnapshot?
    var settings: DemoSettings {
        didSet {
            if settings != oldValue { settings.save(to: defaults) }
        }
    }

    /// Newest first. Kept in memory for the life of the application only.
    private(set) var conversations: [Conversation] = []
    var selectedConversationID: Conversation.ID?
    private(set) var running: Set<Action> = []
    var errors: [Action: ErrorPresentation] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadTasks: [LlamaModelID: Task<Void, Never>] = [:]
    @ObservationIgnored private let observation = TaskBox()

    /// The demo's limits: one resident model, one generation, four waiting requests.
    static let limits = LlamaRuntime.Limits(maximumResidentModels: 1, maximumActiveGenerations: 1, maximumWaitingRequests: 4)

    /// - Parameters:
    ///   - storeRoot: nil uses Application Support.
    ///   - sessionIdentifier: the background session of the downloads; nil for a foreground one.
    init(defaults: UserDefaults = .standard, storeRoot: URL? = nil,
         sessionIdentifier: String? = LlamaModelDownloads.defaultSessionIdentifier,
         catalogURL: URL? = Bundle.main.url(forResource: "models", withExtension: "json")) {
        self.defaults = defaults
        settings = DemoSettings.load(from: defaults)
        var errors: [String] = []

        var catalog: LlamaModelCatalog?
        do {
            guard let catalogURL else { throw CocoaError(.fileNoSuchFile) }
            catalog = try LlamaModelCatalog.decode(Data(contentsOf: catalogURL))
        } catch {
            errors.append("The model catalog is unavailable: \(error.localizedDescription)")
        }
        self.catalog = catalog

        var runtime: LlamaRuntime?
        var downloads: LlamaModelDownloads?
        do {
            let store = try storeRoot.map { try LlamaModelStore(root: $0) } ?? LlamaModelStore.applicationSupport()
            let created = try LlamaRuntime(configuration: LlamaRuntime.Configuration(limits: Self.limits), store: store)
            runtime = created
            // Created at launch with the same identifier, so that a background
            // launch reattaches the transfers the system kept.
            downloads = try LlamaModelDownloads(runtime: created,
                                                configuration: .init(sessionIdentifier: sessionIdentifier))
        } catch {
            errors.append("The llama.cpp runtime could not start: \(error.localizedDescription)")
        }
        self.runtime = runtime
        self.downloads = downloads
        setupErrors = errors

        if let runtime {
            runtimeSnapshot = runtime.snapshot()
            observation.task = Task { [weak self] in
                for await update in runtime.updates() {
                    guard let self else { return }
                    self.runtimeSnapshot = update.snapshot
                    self.runtimeChanged()
                }
            }
        }
        if let downloads {
            downloadsSnapshot = downloads.snapshot()
            observation.task = Task { [weak self] in
                for await update in downloads.updates() {
                    self?.downloadsSnapshot = update.snapshot
                }
            }
        }
        runtimeChanged()
    }

    // MARK: Models

    var installedModels: [LlamaRuntimeSnapshot.Model] { runtimeSnapshot?.models ?? [] }

    func installed(_ id: LlamaModelID) -> LlamaRuntimeSnapshot.Model? { runtimeSnapshot?[id] }

    func download(_ id: LlamaModelID) -> LlamaModelDownload? { downloadsSnapshot?[id] }

    var selectedModel: LlamaRuntimeSnapshot.Model? { settings.selectedModel.flatMap(installed) }

    /// Starts a new conversation when the selected model or its profile changes.
    private func runtimeChanged() {
        if selectedModel == nil, let first = installedModels.first {
            settings.selectedModel = first.id
        }
        if let model = selectedModel, !conversations.contains(where: { $0.modelID == model.id }) {
            startConversation()
        }
    }

    /// The profile the library loads and new conversations use: the current
    /// conversation's when it uses this model, otherwise from the settings.
    func profile(for model: LlamaRuntimeSnapshot.Model) -> LlamaLoadProfile {
        if let conversation = currentConversation, conversation.modelID == model.id, let profile = conversation.profile {
            return profile
        }
        return settings.profile(for: model.artifact)
    }

    func run(_ action: Action, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !running.contains(action) else { return }
        running.insert(action)
        errors[action] = nil
        Task {
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                errors[action] = ErrorPresentation(error)
            }
            running.remove(action)
        }
    }

    func startDownload(_ entry: LlamaModelCatalog.Entry) {
        errors[.download(entry.id)] = nil
        do {
            try downloads?.start(entry)
        } catch {
            errors[.download(entry.id)] = ErrorPresentation(error)
        }
    }

    func pauseDownload(_ id: LlamaModelID) {
        guard let downloads else { return }
        run(.download(id)) { try await downloads.pause(id) }
    }

    func resumeDownload(_ id: LlamaModelID) {
        errors[.download(id)] = nil
        do {
            try downloads?.resume(id)
        } catch {
            errors[.download(id)] = ErrorPresentation(error)
        }
    }

    func cancelDownload(_ id: LlamaModelID) {
        guard let downloads else { return }
        run(.download(id)) { try await downloads.cancel(id) }
    }

    /// Loads the model now; a generation would load it anyway. Cancelling
    /// (background) stops the wait, not a load the engine already started.
    func load(_ model: LlamaRuntimeSnapshot.Model) {
        guard let runtime, !running.contains(.load(model.id)) else { return }
        let profile = profile(for: model)
        let id = model.id
        running.insert(.load(id))
        errors[.load(id)] = nil
        loadTasks[id] = Task {
            do {
                try await runtime.load(id, profile: profile)
            } catch is CancellationError {
            } catch {
                errors[.load(id)] = ErrorPresentation(error)
            }
            running.remove(.load(id))
            loadTasks[id] = nil
        }
    }

    /// Ends the model's generations (of every conversation) and frees it; the
    /// conversations keep their history and may send again.
    func unload(_ id: LlamaModelID) {
        guard let runtime else { return }
        run(.unload(id)) { try await runtime.unload(id) }
    }

    /// Deletes the managed copy (never the file an import was made from).
    func remove(_ id: LlamaModelID) {
        guard let runtime else { return }
        run(.remove(id)) { [weak self] in
            try await runtime.removeModel(id)
            if self?.settings.selectedModel == id {
                self?.settings.selectedModel = nil
            }
        }
    }

    /// Copies a GGUF file (and its projector) into the store. Imported models
    /// get no capability beyond guided generation: their name proves nothing.
    func importModel(name: String, weights: URL, projector: URL?) async -> Bool {
        guard let runtime else { return false }
        running.insert(.importModel)
        errors[.importModel] = nil
        defer { running.remove(.importModel) }
        let urls = [weights, projector].compactMap { $0 }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.modelID(for: trimmed.isEmpty ? weights.deletingPathExtension().lastPathComponent : trimmed,
                              existing: Set(installedModels.map(\.id)))
        do {
            let artifact = try await runtime.importModel(LlamaModelImport(
                id: id, displayName: trimmed.isEmpty ? nil : trimmed, weights: weights, projector: projector))
            selectModel(artifact.id)
            return true
        } catch {
            errors[.importModel] = ErrorPresentation(error)
            return false
        }
    }

    /// A valid, unused model identifier from a display name.
    static func modelID(for name: String, existing: Set<LlamaModelID>) -> LlamaModelID {
        var base = String(name.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
                ? Character(scalar) : "-"
        })
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(100))
        if base.isEmpty { base = "model" }
        var candidate = LlamaModelID(base)
        var counter = 2
        while existing.contains(candidate) {
            candidate = LlamaModelID("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    // MARK: Conversations

    var currentConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    /// Choosing another model starts a new conversation; the others stay.
    func selectModel(_ id: LlamaModelID) {
        settings.selectedModel = id
        guard let model = installed(id) else { return }
        if let current = currentConversation, current.modelID == id,
           current.profile == settings.profile(for: model.artifact) {
            return
        }
        startConversation()
    }

    /// A new conversation with the selected model and the current settings.
    /// An empty conversation it replaces is dropped.
    func startConversation() {
        guard let runtime, let model = selectedModel else { return }
        let profile = settings.profile(for: model.artifact)
        let monitor = LlamaGenerationMonitor()
        let languageModel = LlamaLanguageModel(runtime: runtime, modelID: model.id, profile: profile, monitor: monitor)
        let conversation = Conversation(modelID: model.id, modelName: model.artifact.displayName, profile: profile,
                                        model: languageModel, monitor: monitor,
                                        visionUnavailableReason: Self.visionUnavailableReason(model.artifact, profile))
        conversations.removeAll { $0.turns.isEmpty && !$0.isResponding }
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
    }

    /// Adds a conversation built elsewhere (a history supplied by the
    /// application, or a scripted model in tests) and shows it.
    func insert(_ conversation: Conversation) {
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
    }

    /// The model of a conversation is still installed.
    func isAvailable(_ conversation: Conversation) -> Bool {
        installed(conversation.modelID) != nil
    }

    static func visionUnavailableReason(_ artifact: LlamaModelArtifact, _ profile: LlamaLoadProfile) -> String {
        guard let entry = artifact.catalogEntry else {
            return "Imported models get no image input: their capabilities are not qualified."
        }
        guard entry.qualifiedCapabilities.contains(.vision) else {
            return "\(artifact.displayName) has no qualified image input."
        }
        guard artifact.projector != nil, profile.usesProjector else {
            return "Turn on “Load the projector” in Settings, then start a new conversation."
        }
        return "Image input is unavailable."
    }

    // MARK: Lifecycle

    func scenePhaseChanged(from old: ScenePhase, to new: ScenePhase) {
        if LifecyclePolicy.cancelsInference(from: old, to: new) {
            cancelInference(reason: LifecyclePolicy.backgroundReason)
        }
    }

    /// Cancels every generation and the waits of explicit loads. Nothing
    /// resumes by itself; downloads continue.
    func cancelInference(reason: String) {
        for conversation in conversations {
            conversation.cancel(reason: reason)
        }
        for task in loadTasks.values {
            task.cancel()
        }
    }
}
