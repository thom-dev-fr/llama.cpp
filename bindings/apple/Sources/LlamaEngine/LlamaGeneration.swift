import Foundation

/// One generation admitted by a `LlamaRuntime`: a native request holding an
/// admission permit until its terminal event.
///
/// Pull-based: each `next` reads the native request, so no event is buffered
/// in Swift; the engine bounds its own queue and ends a request whose reader
/// falls behind with `queue_full` instead of dropping deltas. The permit is
/// released once, at the terminal event, on cancellation, when the runtime
/// closes the generation (unload, removal) or when the handle goes away.
package final class LlamaGeneration: @unchecked Sendable {
    package let id = UUID()
    package let model: LlamaModelID
    package let profile: LlamaLoadProfile
    private let onFinish: @Sendable (UUID) -> Void

    private let lock = NSLock()
    // guarded by lock
    private var request: NativeRequest?
    private var permit: AdmissionPermit?
    private var closure: LlamaEngineError?
    private var finished = false

    init(model: LlamaModelID, profile: LlamaLoadProfile, permit: AdmissionPermit,
         onFinish: @escaping @Sendable (UUID) -> Void) {
        self.model = model
        self.profile = profile
        self.permit = permit
        self.onFinish = onFinish
    }

    deinit {
        finish() // the native request, if any, is cancelled by its own destruction
    }

    /// Attaches the native request, unless the runtime closed the generation
    /// meanwhile: then the request is cancelled at once and never runs on.
    func attach(_ request: NativeRequest) throws {
        let closed: LlamaEngineError? = lock.withLock {
            if closure == nil && !finished {
                self.request = request
                return nil
            }
            return closure ?? .unloaded(model)
        }
        if let closed {
            request.cancel()
            throw closed
        }
    }

    /// Ends the generation from the runtime: cancels the native work and
    /// returns the permit. The reader then sees `reason`.
    func close(_ reason: LlamaEngineError) {
        let request: NativeRequest? = lock.withLock {
            if closure == nil && !finished {
                closure = reason
            }
            return self.request
        }
        request?.cancel()
        finish()
    }

    /// Cancels the native work; the reader then sees the cancellation.
    package func cancel() {
        lock.withLock { request }?.cancel()
    }

    var isFinished: Bool { lock.withLock { finished } }

    private func finish() {
        let (permit, first): (AdmissionPermit?, Bool) = lock.withLock {
            defer {
                self.permit = nil
                finished = true
            }
            return (self.permit, !finished)
        }
        permit?.release()
        if first {
            onFinish(id)
        }
    }

    /// Next payload, then the success event, then nil. A native error or
    /// cancellation is thrown, typed when possible (context overflow, unload).
    package func next() async throws -> NativeEvent? {
        let (request, closure, finished) = lock.withLock { (self.request, self.closure, self.finished) }
        guard let request else {
            if finished { return nil }
            throw closure ?? LlamaEngineError.engineUnavailable("generation without native request")
        }
        if finished, let closure {
            throw closure
        }
        while true {
            // A cancelled task cancels the native request: its end arrives as an event.
            let event = try await request.next()
            switch event.kind {
            case .payload:
                return event
            case .timeout:
                continue
            case .success:
                finish()
                return event
            case .cancelled, .error:
                finish()
                throw translate(event)
            }
        }
    }

    private func translate(_ event: NativeEvent) -> any Error {
        if event.category == "context_exceeded", let overflow = LlamaContextOverflow(errorData: event.data) {
            return LlamaEngineError.contextExceeded(overflow)
        }
        if event.kind == .cancelled, let closure = lock.withLock({ closure }) {
            return closure
        }
        return event.error
    }

    /// The events until the terminal one (see `next`).
    package func events() -> Events {
        Events(generation: self)
    }

    package struct Events: AsyncSequence, Sendable {
        package typealias Element = NativeEvent
        let generation: LlamaGeneration

        package struct AsyncIterator: AsyncIteratorProtocol {
            let generation: LlamaGeneration
            var done = false

            package mutating func next() async throws -> NativeEvent? {
                guard !done else { return nil }
                do {
                    let event = try await generation.next()
                    if event == nil || event?.kind == .success {
                        done = true
                    }
                    return event
                } catch {
                    done = true
                    throw error
                }
            }
        }

        package func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(generation: generation)
        }
    }
}
