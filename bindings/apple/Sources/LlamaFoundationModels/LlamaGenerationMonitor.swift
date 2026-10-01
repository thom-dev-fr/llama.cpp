import Foundation
public import LlamaEngine

/// What the requests of a `LlamaLanguageModel` value are doing, for display:
/// phase, prompt processing progress and context occupancy.
///
/// Give one monitor to the model value of a conversation
/// (`LlamaLanguageModel(..., monitor:)`); `LanguageModelSession.usage` is a
/// cumulated consumption and never an occupancy. Outside a request, the last
/// measure stays available and is marked as such: it does not claim to
/// describe a cache still resident. No measure is `nil`, never zero.
public final class LlamaGenerationMonitor: Sendable {
    public struct State: Hashable, Sendable {
        public enum Phase: Hashable, Sendable {
            /// No request is running.
            case idle
            /// Waiting for admission or for the model to be resident.
            case waiting
            /// The engine processes the prompt.
            case processingPrompt
            /// Tokens are being generated.
            case generating
        }

        public var phase: Phase
        /// The running request (the Foundation Models request identifier).
        public var requestID: UUID?
        /// Share of the prompt processed, cache included, in 0...1; nil before
        /// the first progress report of the request.
        public var promptProgress: Double?
        /// The latest context report of the running request, or of the last
        /// request when `isContextLive` is false. Nil when none was received.
        public var context: LlamaContextReport?
        /// The context report belongs to the running request.
        public var isContextLive: Bool

        public static let initial = State(phase: .idle, requestID: nil, promptProgress: nil, context: nil,
                                          isContextLive: false)
    }

    private let lock = NSLock()
    // guarded by lock
    nonisolated(unsafe) private var current = State.initial
    nonisolated(unsafe) private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]

    public init() {}

    public var state: State {
        lock.withLock { current }
    }

    /// The current state, then each change. A slow reader only misses
    /// intermediate states (the newest one is kept): states, unlike deltas,
    /// may be coalesced.
    public func updates() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let state: State = lock.withLock {
            continuations[id] = continuation
            return current
        }
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func update(_ change: (inout State) -> Void) {
        let (state, targets): (State, [AsyncStream<State>.Continuation]) = lock.withLock {
            var state = current
            change(&state)
            guard state != current else { return (state, []) }
            current = state
            return (state, Array(continuations.values))
        }
        for continuation in targets {
            continuation.yield(state)
        }
    }

    func begin(_ requestID: UUID) {
        update {
            $0 = State(phase: .waiting, requestID: requestID, promptProgress: nil, context: $0.context, isContextLive: false)
        }
    }

    /// The request ended: its last report stays, marked as not live.
    func end(_ requestID: UUID) {
        update {
            guard $0.requestID == requestID else { return }
            $0.phase = .idle
            $0.requestID = nil
            $0.promptProgress = nil
            $0.isContextLive = false
        }
    }
}
