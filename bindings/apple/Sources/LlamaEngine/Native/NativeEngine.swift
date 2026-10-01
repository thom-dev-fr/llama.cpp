import Foundation
internal import LlamaBridge

// Swift side of the C bridge (bindings/apple/bridge/include/llama_bridge.h).
// Package access: applications use LlamaRuntime and LlamaLanguageModel.
//
// Blocking native calls (next, unload, catalog updates, stop, destruction and
// the preparation done by submit) run on NativeWorkers, never on the Swift
// cooperative pool or the main actor: an `async` function alone would block
// one of its threads.

/// Threads for blocking native calls.
package final class NativeWorkers: Sendable {
    private let queue: DispatchQueue

    package init(label: String = "org.ggml.llama.native") {
        queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
    }

    package func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    package func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Fire and forget, for destructions from deinit.
    package func detach(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}

/// One event of the engine, copied out of the native event.
package struct NativeEvent: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case payload, success, error, cancelled, timeout
    }

    package var kind: Kind
    /// JSON text of the native payload or result ("null" when absent).
    package var data: Data
    package var category: String
    package var message: String

    package var isTerminal: Bool { kind == .success || kind == .error || kind == .cancelled }

    init(_ event: OpaquePointer) {
        switch llama_bridge_event_get_type(event) {
        case LLAMA_BRIDGE_EVENT_PAYLOAD: kind = .payload
        case LLAMA_BRIDGE_EVENT_SUCCESS: kind = .success
        case LLAMA_BRIDGE_EVENT_CANCELLED: kind = .cancelled
        case LLAMA_BRIDGE_EVENT_TIMEOUT: kind = .timeout
        default: kind = .error
        }
        data = Data(String(cString: llama_bridge_event_get_data(event)).utf8)
        category = String(cString: llama_bridge_event_get_category(event))
        message = String(cString: llama_bridge_event_get_message(event))
    }

    /// Takes ownership of a native event (NULL only when out of memory).
    static func consume(_ event: OpaquePointer?) -> NativeEvent {
        guard let event else {
            return NativeEvent(kind: .error, data: Data("null".utf8), category: "out_of_memory", message: "out of memory")
        }
        defer { llama_bridge_event_free(event) }
        return NativeEvent(event)
    }

    package init(kind: Kind, data: Data, category: String, message: String) {
        self.kind = kind
        self.data = data
        self.category = category
        self.message = message
    }

    package var error: LlamaEngineError {
        .native(category: category, message: message, details: data)
    }
}

/// Owned bytes referenced as "attachment:<name>" in a request.
package struct NativeAttachment: Sendable {
    package var name: String
    package var bytes: Data

    package init(name: String, bytes: Data) {
        self.name = name
        self.bytes = bytes
    }
}

/// A native handle handed to a worker for its destruction.
private struct Owned: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Calls a bridge function with an error out-parameter; a NULL result throws.
private func checked<T>(_ body: (UnsafeMutablePointer<OpaquePointer?>) -> T?) throws -> T {
    var error: OpaquePointer?
    if let value = body(&error) {
        return value
    }
    throw NativeEvent.consume(error).error
}

/// A native engine with its catalog. Destroyed (stopped and joined) on a worker
/// when the last reference goes; requests and subscriptions may outlive it.
package final class NativeEngine: @unchecked Sendable {
    // Immutable after init; the native engine is thread-safe for these calls.
    private let handle: OpaquePointer
    package let workers: NativeWorkers

    private init(handle: OpaquePointer, workers: NativeWorkers) {
        self.handle = handle
        self.workers = workers
    }

    deinit {
        let owned = Owned(pointer: handle)
        workers.detach { llama_bridge_engine_destroy(owned.pointer) }
    }

    /// Creates an engine from a catalog configuration (see llama_bridge.h).
    /// Nothing is loaded: a catalog engine starts its threads and returns.
    package static func createCatalog(configuration: Data, workers: NativeWorkers) throws -> NativeEngine {
        let json = String(decoding: configuration, as: UTF8.self)
        let handle = try checked { llama_bridge_engine_create(json, $0) }
        return NativeEngine(handle: handle, workers: workers)
    }

    /// Same, on a worker.
    package static func create(configuration: Data, workers: NativeWorkers) async throws -> NativeEngine {
        let json = String(decoding: configuration, as: UTF8.self)
        let address = try await workers.run { () throws -> UInt in
            let handle = try checked { llama_bridge_engine_create(json, $0) }
            return UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(handle)))
        }
        let handle = OpaquePointer(bitPattern: address)!
        return NativeEngine(handle: handle, workers: workers)
    }

    /// Submits a request; its preparation (template, tokens, media) runs on a worker.
    package func submit(_ operation: String, body: Data, attachments: [NativeAttachment] = []) async throws -> NativeRequest {
        let json = String(decoding: body, as: UTF8.self)
        return try await workers.run { [self] in
            try NativeRequest(owner: self) { error in
                withAttachments(attachments) { pointer, count in
                    llama_bridge_engine_submit(handle, operation, json, pointer, count, error)
                }
            }
        }
    }

    /// Loads a model; the request succeeds once the model is resident.
    package func load(model: String) async throws -> NativeRequest {
        try await workers.run { [self] in
            try NativeRequest(owner: self) { llama_bridge_engine_load(handle, model, $0) }
        }
    }

    /// Catalog snapshot (JSON array).
    package func catalog() throws -> Data {
        let text = try checked { llama_bridge_engine_catalog(handle, $0) }
        defer { llama_bridge_string_free(text) }
        return Data(String(cString: text).utf8)
    }

    /// Explicit unload: waits until the model's work stopped and its resources are freed.
    package func unload(model: String) async -> NativeEvent {
        await workers.run { [self] in NativeEvent.consume(llama_bridge_engine_unload(handle, model)) }
    }

    /// Replaces the catalog models (JSON array).
    package func updateCatalog(models: Data) async -> NativeEvent {
        let json = String(decoding: models, as: UTF8.self)
        return await workers.run { [self] in NativeEvent.consume(llama_bridge_engine_update_catalog(handle, json)) }
    }

    package func subscribe() throws -> NativeSubscription {
        let subscription = try checked { llama_bridge_engine_subscribe(handle, $0) }
        return NativeSubscription(handle: subscription, workers: workers)
    }

    /// Closes admissions, cancels the work, wakes the readers and joins.
    package func stop() async {
        await workers.run { [self] in llama_bridge_engine_stop(handle) }
    }
}

private func withAttachments<R>(_ attachments: [NativeAttachment],
                                _ body: (UnsafePointer<llama_bridge_attachment>?, Int) -> R) -> R {
    // The bridge copies names and bytes before returning.
    func nest(_ index: Int, _ built: [llama_bridge_attachment]) -> R {
        guard index < attachments.count else {
            return built.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
        }
        return attachments[index].name.withCString { name in
            attachments[index].bytes.withUnsafeBytes { bytes in
                nest(index + 1, built + [llama_bridge_attachment(
                    name: name, bytes: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)])
            }
        }
    }
    return nest(0, [])
}

/// A native request with one reader at a time. Cancelling the Swift task that
/// waits in `next` cancels the native request; the handle is destroyed (which
/// also cancels unfinished work) when the last reference goes.
package final class NativeRequest: @unchecked Sendable {
    private let handle: OpaquePointer
    private let workers: NativeWorkers
    private let reading = NSLock()
    private var isReading = false // guarded by reading

    fileprivate init(owner: NativeEngine,
                     _ create: (UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?) throws {
        handle = try checked(create)
        workers = owner.workers
    }

    deinit {
        let owned = Owned(pointer: handle)
        workers.detach { llama_bridge_request_destroy(owned.pointer) }
    }

    /// Next event; nil timeout waits without limit. A cancelled task cancels
    /// the native request, whether it is cancelled during the wait or before
    /// the call: the reader then drains the payloads already produced and gets
    /// the terminal `cancelled` event. Throws only for a concurrent reader.
    package func next(timeout: Duration? = nil) async throws -> NativeEvent {
        if Task.isCancelled {
            llama_bridge_request_cancel(handle)
        }
        try reading.withLock {
            guard !isReading else { throw LlamaEngineError.concurrentReaders }
            isReading = true
        }
        defer { reading.withLock { isReading = false } }
        let milliseconds: Int64 = timeout.map { Int64($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) } ?? -1
        return await withTaskCancellationHandler {
            await workers.run { [self] in NativeEvent.consume(llama_bridge_request_next(handle, milliseconds)) }
        } onCancel: {
            llama_bridge_request_cancel(handle)
        }
    }

    /// Cancels the native work; safe while another task reads.
    package func cancel() {
        llama_bridge_request_cancel(handle)
    }

    /// Payloads until the terminal event, which is returned (success) or thrown.
    /// Pull-based: nothing is buffered in Swift, the engine's bounded event
    /// queue applies (a reader that falls behind ends the request with queue_full).
    package func events() -> Events {
        Events(request: self)
    }

    package struct Events: AsyncSequence, Sendable {
        package typealias Element = NativeEvent
        let request: NativeRequest

        package struct AsyncIterator: AsyncIteratorProtocol {
            let request: NativeRequest
            var done = false

            package mutating func next() async throws -> NativeEvent? {
                while !done {
                    let event = try await request.next()
                    switch event.kind {
                    case .payload:
                        return event
                    case .timeout:
                        continue
                    case .success:
                        done = true
                        return event
                    case .cancelled, .error:
                        done = true
                        throw event.error
                    }
                }
                return nil
            }
        }

        package func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(request: request)
        }
    }
}

/// Model state events of an engine; one reader at a time.
package final class NativeSubscription: @unchecked Sendable {
    private let handle: OpaquePointer
    private let workers: NativeWorkers

    fileprivate init(handle: OpaquePointer, workers: NativeWorkers) {
        self.handle = handle
        self.workers = workers
    }

    deinit {
        let owned = Owned(pointer: handle)
        workers.detach { llama_bridge_subscription_destroy(owned.pointer) }
    }

    package func next(timeout: Duration) async -> NativeEvent {
        let milliseconds = Int64(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return await workers.run { [self] in NativeEvent.consume(llama_bridge_subscription_next(handle, milliseconds)) }
    }
}
