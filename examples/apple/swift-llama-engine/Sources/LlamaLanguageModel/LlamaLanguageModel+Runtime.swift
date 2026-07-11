import Foundation
import LlamaEngine
#if os(iOS)
import UIKit
#endif

@available(iOS 27.0, macOS 27.0, *)
final class LlamaLanguageModelRuntimeStorage: @unchecked Sendable {
    let runtime: LlamaLanguageModelRuntime
    private let lifecycleObserver: LlamaLanguageModelLifecycleObserver?

    init(configuration: LlamaLanguageModel.Executor.Configuration) {
        let runtime = LlamaLanguageModelRuntime(configuration: configuration)
        self.runtime = runtime
        self.lifecycleObserver = LlamaLanguageModelLifecycleObserver(runtime: runtime)
    }

    deinit {
        let runtime = runtime
        Task {
            await runtime.shutdown()
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
actor LlamaLanguageModelRuntime {
    private let engine = LlamaEngine()
    private let configuration: LlamaLanguageModel.Executor.Configuration
    private var loaded = false
    private var loadTask: Task<Void, any Error>?
    private var isGenerating = false
    private var isShuttingDown = false
    private var lastLoadError: (any Error)?

    init(configuration: LlamaLanguageModel.Executor.Configuration) {
        self.configuration = configuration
    }

    func prewarm() {
        guard !isShuttingDown, !loaded, loadTask == nil else { return }

        let engine = engine
        let modelConfiguration = configuration.configuration
        let task = Task {
            try await engine.load(modelConfiguration)
        }
        loadTask = task

        Task {
            do {
                try await task.value
                self.finishLoad(success: true)
            } catch {
                self.finishLoad(success: false, error: error)
            }
        }
    }

    func beginGeneration() async throws -> LlamaEngine {
        guard !isShuttingDown else {
            throw LlamaError.cancelled
        }

        guard !isGenerating else {
            throw LlamaLanguageModelError.concurrentGeneration
        }

        isGenerating = true
        do {
            try await ensureLoadedOrResumed()
            return engine
        } catch {
            isGenerating = false
            throw error
        }
    }

    func endGeneration() {
        isGenerating = false
    }

    func availability() -> LlamaLanguageModel.Availability {
        switch engine.state {
        case .ready:     return .ready
        case .loading:   return .loading
        case .resuming:  return .resuming
        case .pausing:   return .pausing
        case .paused:    return .paused
        case .unloading: return .unloading
        case .unloaded:
            if !modelFilesPresent {
                return .unavailable(.modelFileMissing)
            }
            if lastLoadError != nil {
                return .unavailable(.loadFailed)
            }
            return .available
        }
    }

    func pauseForBackground() async {
        guard !isShuttingDown, loaded, !isGenerating, engine.state == .ready else { return }
        try? await engine.pause()
    }

    func resumeForForeground() async {
        guard !isShuttingDown, loaded, engine.state == .paused else { return }
        try? await engine.resume()
    }

    func shutdown() async {
        isShuttingDown = true
        let pendingLoad = loadTask
        pendingLoad?.cancel()

        if let pendingLoad {
            try? await pendingLoad.value
        }

        guard !isGenerating else { return }
        guard engine.state != .unloaded else {
            loaded = false
            loadTask = nil
            return
        }

        try? await engine.unload()
        loaded = false
        loadTask = nil
    }

    private func ensureLoadedOrResumed() async throws {
        if loaded {
            switch engine.state {
            case .paused:
                try await engine.resume()
            case .unloaded:
                loaded = false
            default:
                return
            }
        }

        if let loadTask {
            do {
                try await loadTask.value
                loaded = true
                self.loadTask = nil
                lastLoadError = nil
                return
            } catch {
                self.loadTask = nil
                lastLoadError = error
                throw error
            }
        }

        let engine = engine
        let modelConfiguration = configuration.configuration
        let task = Task {
            try await engine.load(modelConfiguration)
        }
        loadTask = task

        do {
            try await task.value
            loaded = true
            loadTask = nil
            lastLoadError = nil
        } catch {
            loadTask = nil
            lastLoadError = error
            throw error
        }
    }

    private var modelFilesPresent: Bool {
        let fileManager = FileManager.default
        let modelConfiguration = configuration.configuration
        guard fileManager.fileExists(atPath: modelConfiguration.modelPath.path) else {
            return false
        }
        if let projectorPath = modelConfiguration.mtmdProjectorPath {
            guard fileManager.fileExists(atPath: projectorPath.path) else {
                return false
            }
        }
        return true
    }

    private func finishLoad(success: Bool, error: (any Error)? = nil) {
        guard !isShuttingDown else {
            loaded = false
            loadTask = nil
            return
        }

        loaded = success
        loadTask = nil
        lastLoadError = success ? nil : error
    }
}

@available(iOS 27.0, macOS 27.0, *)
private final class LlamaLanguageModelLifecycleObserver: @unchecked Sendable {
    private let runtime: LlamaLanguageModelRuntime

    #if os(iOS)
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    #endif

    init(runtime: LlamaLanguageModelRuntime) {
        self.runtime = runtime

        #if os(iOS)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [runtime] _ in
            Task { await runtime.pauseForBackground() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [runtime] _ in
            Task { await runtime.resumeForForeground() }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        #endif
    }
}
