import Foundation

// The single admission authority of a runtime. A generation runs only with a
// permit; at most `capacity` permits exist, and at most `waitingCapacity`
// requests wait for one, first come first served. Each native model instance
// has as many slots as permits, so an admitted generation never queues again
// in the engine for a slot (it may still wait there for its model to load).

/// Counts published in snapshots.
struct AdmissionCounts: Hashable, Sendable {
    var active = 0
    var waiting = 0
    var waitingByModel: [LlamaModelID: Int] = [:]
}

final class Admission: @unchecked Sendable {
    let capacity: Int
    let waitingCapacity: Int
    private let timeout: Duration?
    private let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private var active = 0          // guarded by lock
    private var queue: [Ticket] = [] // guarded by lock

    init(capacity: Int, waitingCapacity: Int, timeout: Duration?, onChange: @escaping @Sendable () -> Void) {
        self.capacity = capacity
        self.waitingCapacity = waitingCapacity
        self.timeout = timeout
        self.onChange = onChange
    }

    private final class Ticket: @unchecked Sendable {
        enum State { case pending, waiting, granted, failed }
        let model: LlamaModelID
        // guarded by Admission.lock
        var state = State.pending
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
        var timer: Task<Void, Never>?

        init(model: LlamaModelID) {
            self.model = model
        }
    }

    var counts: AdmissionCounts {
        lock.withLock {
            var counts = AdmissionCounts(active: active, waiting: queue.count)
            for ticket in queue {
                counts.waitingByModel[ticket.model, default: 0] += 1
            }
            return counts
        }
    }

    /// Waits for a permit. Throws `queueFull` at once when the queue is full,
    /// `admissionTimedOut` after the configured wait, `CancellationError` when
    /// the task is cancelled while waiting, or the error given to `close`.
    func acquire(model: LlamaModelID) async throws -> AdmissionPermit {
        try Task.checkCancellation()
        let ticket = Ticket(model: model)
        let immediate: Bool = try lock.withLock {
            if queue.isEmpty && active < capacity {
                active += 1
                ticket.state = .granted
                return true
            }
            guard queue.count < waitingCapacity else {
                throw LlamaEngineError.queueFull(waitingCapacity: waitingCapacity)
            }
            return false
        }
        if immediate {
            onChange()
            return AdmissionPermit(admission: self)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let enqueued: Bool = lock.withLock {
                    if ticket.state == .failed { // cancelled before it could wait
                        return false
                    }
                    ticket.state = .waiting
                    ticket.continuation = continuation
                    queue.append(ticket)
                    return true
                }
                guard enqueued else {
                    continuation.resume(throwing: ticket.failure ?? CancellationError())
                    return
                }
                if let timeout {
                    let timer = Task { [weak self, ticket] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.fail(ticket, LlamaEngineError.admissionTimedOut(timeout))
                    }
                    lock.withLock { ticket.timer = timer }
                }
                onChange()
            }
        } onCancel: {
            fail(ticket, CancellationError())
        }
        return AdmissionPermit(admission: self)
    }

    /// Ends a waiting ticket once; a ticket already granted or failed is left alone.
    private func fail(_ ticket: Ticket, _ error: any Error) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            switch ticket.state {
            case .pending:
                ticket.state = .failed
                ticket.failure = error
                return nil
            case .waiting:
                queue.removeAll { $0 === ticket }
                ticket.state = .failed
                ticket.timer?.cancel()
                let continuation = ticket.continuation
                ticket.continuation = nil
                return continuation
            case .granted, .failed:
                return nil
            }
        }
        if let continuation {
            continuation.resume(throwing: error)
            onChange()
        }
    }

    /// Fails every request of `model` still waiting for admission.
    func close(model: LlamaModelID, error: any Error) {
        let tickets = lock.withLock { queue.filter { $0.model == model } }
        for ticket in tickets {
            fail(ticket, error)
        }
    }

    /// Returns a permit and grants the next waiting requests.
    fileprivate func release() {
        let granted: [CheckedContinuation<Void, any Error>] = lock.withLock {
            active -= 1
            var granted: [CheckedContinuation<Void, any Error>] = []
            while active < capacity, !queue.isEmpty {
                let ticket = queue.removeFirst()
                ticket.state = .granted
                ticket.timer?.cancel()
                active += 1
                if let continuation = ticket.continuation {
                    granted.append(continuation)
                }
                ticket.continuation = nil
            }
            return granted
        }
        for continuation in granted {
            continuation.resume()
        }
        onChange()
    }
}

/// The right to run one generation. Released once: explicitly, at the end of
/// the generation, or when the permit is deallocated.
final class AdmissionPermit: @unchecked Sendable {
    private weak var admission: Admission?
    private let lock = NSLock()
    private var released = false // guarded by lock

    fileprivate init(admission: Admission) {
        self.admission = admission
    }

    deinit {
        release()
    }

    func release() {
        let first = lock.withLock {
            defer { released = true }
            return !released
        }
        if first {
            admission?.release()
        }
    }
}
