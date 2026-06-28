import Foundation
import LlamaEngineCore

/// Single-consumer chat completion stream produced by `LlamaEngine`.
///
/// The stream owns the underlying C stream handle. `cancel()` is idempotent and
/// crosses the C seam immediately; `deinit` always closes the handle.
public final class EngineStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = String

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: EngineStream?
        private let alreadyConsumed: Bool

        init(stream: EngineStream?, alreadyConsumed: Bool) {
            self.stream = stream
            self.alreadyConsumed = alreadyConsumed
        }

        public mutating func next() async throws -> String? {
            if alreadyConsumed {
                throw LlamaError.streamAlreadyConsumed
            }
            guard let stream else { return nil }
            return try await stream.next()
        }
    }

    private let engine: LlamaEngine
    private let stateLock = NSLock()
    private let nextLock = NSLock()
    private var handle: OpaquePointer?
    private var consumed = false
    private var cancelled = false
    private var finished = false

    init(engine: LlamaEngine, handle: OpaquePointer) {
        self.engine = engine
        self.handle = handle
    }

    deinit {
        close()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stateLock.lock()
        let alreadyConsumed = consumed
        if !consumed {
            consumed = true
        }
        stateLock.unlock()
        return AsyncIterator(stream: self, alreadyConsumed: alreadyConsumed)
    }

    /// Requests cancellation of the underlying generation. Safe to call more
    /// than once and from any thread.
    public func cancel() {
        stateLock.lock()
        cancelled = true
        let h = handle
        stateLock.unlock()

        if let h {
            llama_engine_stream_cancel(h)
        }
    }

    private func close() {
        stateLock.lock()
        let h = handle
        handle = nil
        cancelled = true
        finished = true
        stateLock.unlock()

        if let h {
            llama_engine_stream_close(h)
        }
    }

    private func next() async throws -> String? {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try self.nextBlocking()
            }.value
        } onCancel: {
            self.cancel()
        }
    }

    private func nextBlocking() throws -> String? {
        nextLock.lock()
        defer { nextLock.unlock() }

        while true {
            stateLock.lock()
            if finished {
                stateLock.unlock()
                return nil
            }
            if cancelled {
                stateLock.unlock()
                throw LlamaError.cancelled
            }
            guard let h = handle else {
                stateLock.unlock()
                return nil
            }
            stateLock.unlock()

            var chunkPtr: UnsafeMutablePointer<CChar>? = nil
            var done = false
            let status = llama_engine_stream_next(h, &chunkPtr, &done)

            let chunk = chunkPtr.map { String(cString: $0) }
            llama_engine_free_string(chunkPtr)

            if done {
                stateLock.lock()
                finished = true
                stateLock.unlock()
            }

            if status == LLAMA_ENGINE_ERR_INFERENCE {
                let msg = engine.lastErrorMessage() ?? "inference error"
                throw LlamaError.inference(msg, payload: chunk)
            }
            if status == LLAMA_ENGINE_ERR_CANCELLED {
                throw LlamaError.cancelled
            }
            if status != LLAMA_ENGINE_OK {
                let msg = engine.lastErrorMessage() ?? "stream error"
                throw engine.map(status: status, message: msg, payload: chunk)
            }

            if let c = chunk, !c.isEmpty {
                return c
            }

            if done {
                return nil
            }
        }
    }
}
