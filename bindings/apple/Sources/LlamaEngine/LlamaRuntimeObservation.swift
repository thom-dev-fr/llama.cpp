import Foundation

/// State of a runtime at one moment: catalog, loaded instances and admission.
public struct LlamaRuntimeSnapshot: Hashable, Sendable {
    public enum Availability: String, Hashable, Sendable {
        case available
        /// An explicit unload closed the admissions; they reopen afterwards.
        case unloading
        /// The model is being removed from the runtime.
        case removing
    }

    /// State of one loaded or loadable instance (artifact and profile), as
    /// reported by the engine.
    public enum InstanceState: Hashable, Sendable {
        case unloaded
        /// `progress` in 0...1 when the engine reports it.
        case loading(progress: Double?)
        case loaded
        case sleeping
        case unloading
        case failed(String)
    }

    public struct Instance: Hashable, Sendable {
        public var profile: LlamaLoadProfile
        public var state: InstanceState
        /// Requests admitted by the engine on this instance.
        public var activeRequests: Int
        /// Requests waiting in the engine for this instance to load.
        public var loadingRequests: Int
    }

    public struct Model: Hashable, Sendable {
        public var artifact: LlamaModelArtifact
        public var availability: Availability
        /// Profiles used so far; a profile appears once something used it.
        public var instances: [Instance]
        /// Requests of this model waiting for admission.
        public var waitingRequests: Int

        public var id: LlamaModelID { artifact.id }
        public var isLoaded: Bool { instances.contains { $0.state == .loaded || $0.state == .sleeping } }
    }

    public struct Admission: Hashable, Sendable {
        public var activeGenerations: Int
        public var waitingRequests: Int
        public var maximumActiveGenerations: Int
        public var maximumWaitingRequests: Int

        public var isQueueFull: Bool { waitingRequests >= maximumWaitingRequests && activeGenerations >= maximumActiveGenerations }
    }

    /// Models sorted by identifier.
    public var models: [Model]
    public var admission: Admission

    public subscript(id: LlamaModelID) -> Model? {
        models.first { $0.id == id }
    }
}

/// One element of `LlamaRuntime.updates()`. Every element carries the whole
/// snapshot, so a subscriber only needs the latest one.
public enum LlamaRuntimeUpdate: Hashable, Sendable {
    /// The first element: the state when the subscription started.
    case snapshot(LlamaRuntimeSnapshot)
    case changed(LlamaRuntimeSnapshot)
    /// The subscriber fell behind: `droppedUpdates` queued updates were
    /// replaced by this snapshot, which includes their changes.
    case resync(LlamaRuntimeSnapshot, droppedUpdates: Int)

    public var snapshot: LlamaRuntimeSnapshot {
        switch self {
        case .snapshot(let snapshot), .changed(let snapshot), .resync(let snapshot, _): return snapshot
        }
    }
}

/// Runtime updates with a bounded buffer: a slow subscriber gets one `resync`
/// instead of an unbounded queue, never a silent loss. Ends when the task
/// iterating it is cancelled or the runtime shuts down.
public struct LlamaRuntimeUpdates: AsyncSequence, Sendable {
    public typealias Element = LlamaRuntimeUpdate
    public typealias Failure = Never

    let buffer: UpdateBuffer

    public struct AsyncIterator: AsyncIteratorProtocol {
        let buffer: UpdateBuffer

        public mutating func next() async -> LlamaRuntimeUpdate? {
            await buffer.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> LlamaRuntimeUpdate? {
            await buffer.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(buffer: buffer)
    }
}

final class UpdateBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    // guarded by lock
    private var queue: [LlamaRuntimeUpdate] = []
    private var waiter: CheckedContinuation<LlamaRuntimeUpdate?, Never>?
    private var finished = false

    init(limit: Int, first: LlamaRuntimeSnapshot) {
        self.limit = max(1, limit)
        queue = [.snapshot(first)]
    }

    func push(_ snapshot: LlamaRuntimeSnapshot) {
        let resumed: CheckedContinuation<LlamaRuntimeUpdate?, Never>? = lock.withLock {
            guard !finished else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            if queue.count >= limit {
                let dropped = queue.reduce(0) { count, update in
                    if case .resync(_, let earlier) = update { return count + earlier }
                    return count + 1
                }
                queue = [.resync(snapshot, droppedUpdates: dropped)]
            } else {
                queue.append(.changed(snapshot))
            }
            return nil
        }
        resumed?.resume(returning: .changed(snapshot))
    }

    func finish() {
        let resumed: CheckedContinuation<LlamaRuntimeUpdate?, Never>? = lock.withLock {
            finished = true
            queue.removeAll()
            defer { waiter = nil }
            return waiter
        }
        resumed?.resume(returning: nil)
    }

    var isFinished: Bool { lock.withLock { finished } }

    func next() async -> LlamaRuntimeUpdate? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LlamaRuntimeUpdate?, Never>) in
                let ready: LlamaRuntimeUpdate?? = lock.withLock {
                    if !queue.isEmpty { return .some(queue.removeFirst()) }
                    if finished { return .some(nil) }
                    waiter = continuation
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        } onCancel: {
            finish()
        }
    }
}

/// Fan-out of snapshots to the subscribers. Snapshots are built and delivered
/// under one lock, so every subscriber sees them in the same order; equal
/// consecutive snapshots are not repeated.
final class UpdateHub: @unchecked Sendable {
    private struct Weak { weak var buffer: UpdateBuffer? }

    private let lock = NSLock()
    // guarded by lock
    private var buffers: [Weak] = []
    private var last: LlamaRuntimeSnapshot?
    private var closed = false

    func subscribe(limit: Int, make: () -> LlamaRuntimeSnapshot) -> LlamaRuntimeUpdates {
        lock.withLock {
            // `last` stays the snapshot the other subscribers received
            let buffer = UpdateBuffer(limit: limit, first: make())
            if closed {
                buffer.finish()
            } else {
                buffers.append(Weak(buffer: buffer))
            }
            return LlamaRuntimeUpdates(buffer: buffer)
        }
    }

    func publish(_ make: () -> LlamaRuntimeSnapshot) {
        lock.withLock {
            guard !closed else { return }
            let snapshot = make()
            guard snapshot != last else { return }
            last = snapshot
            buffers.removeAll { $0.buffer == nil || $0.buffer!.isFinished }
            for entry in buffers {
                entry.buffer?.push(snapshot)
            }
        }
    }

    func close() {
        let finishing = lock.withLock {
            closed = true
            defer { buffers.removeAll() }
            return buffers.compactMap(\.buffer)
        }
        for buffer in finishing {
            buffer.finish()
        }
    }
}
