import Foundation
import LlamaEngine
import LlamaFoundationModels

/// Occupancy of the context against its effective capacity, from the
/// generation monitor. Never derived from `LanguageModelSession.usage`, which
/// is a cumulated consumption.
struct ContextGauge: Equatable {
    enum Value: Equatable {
        /// No request reported its context yet: unknown, not zero.
        case unavailable
        case measured(occupied: Int, capacity: Int)
    }

    var value: Value
    /// The measure belongs to the running request; otherwise it is the last
    /// one and does not claim to describe a cache still resident.
    var isLive: Bool

    init(_ state: LlamaGenerationMonitor.State) {
        if let context = state.context {
            value = .measured(occupied: context.occupiedTokens, capacity: context.contextSize)
            isLive = state.isContextLive
        } else {
            value = .unavailable
            isLive = false
        }
    }

    var fraction: Double? {
        guard case .measured(let occupied, let capacity) = value, capacity > 0 else { return nil }
        return min(1, Double(occupied) / Double(capacity))
    }

    var label: String {
        switch value {
        case .unavailable: "Unavailable"
        case .measured(let occupied, let capacity): "\(occupied.formatted()) / \(capacity.formatted()) tokens"
        }
    }

    var caption: String {
        switch value {
        case .unavailable: "No request measured yet"
        case .measured: isLive ? "Current request" : "Last measure"
        }
    }
}

/// What the running request of a conversation is waiting for or doing.
struct ActivityStatus: Equatable {
    enum Phase: Equatable {
        case queued(waiting: Int)
        case loadingModel
        case waiting
        case processingPrompt
        case generating
    }

    var phase: Phase
    /// 0...1 when known.
    var progress: Double?

    /// Nil when no request runs.
    init?(monitor: LlamaGenerationMonitor.State, model: LlamaRuntimeSnapshot.Model?, profile: LlamaLoadProfile?,
          admission: LlamaRuntimeSnapshot.Admission?) {
        switch monitor.phase {
        case .idle:
            return nil
        case .processingPrompt:
            phase = .processingPrompt
            progress = monitor.promptProgress
        case .generating:
            phase = .generating
            progress = nil
        case .waiting:
            let instance = model?.instances.first { $0.profile == profile }
            if case .loading(let fraction)? = instance?.state {
                phase = .loadingModel
                progress = fraction
            } else if let admission, admission.activeGenerations >= admission.maximumActiveGenerations,
                      admission.waitingRequests > 0 {
                phase = .queued(waiting: admission.waitingRequests)
                progress = nil
            } else {
                phase = .waiting
                progress = nil
            }
        }
    }

    var label: String {
        switch phase {
        case .queued(let waiting): "Queued (\(waiting) waiting)"
        case .loadingModel: "Loading the model"
        case .waiting: "Waiting for the model"
        case .processingPrompt: "Processing the prompt"
        case .generating: "Generating"
        }
    }
}
