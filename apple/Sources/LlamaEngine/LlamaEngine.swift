import Foundation
import LlamaEngineCore

/// Actor-isolated façade over the C engine. Load / unload / wake and
/// inference are serialised on the actor; `sleep()` is intentionally
/// `nonisolated` so it can preempt an in-flight `load()` or `wake()` (for
/// example when iOS transitions the app to the background).
///
/// The underlying C engine handle is created at `init()` and is immutable for
/// the lifetime of this object, which lets us expose it safely outside the
/// actor. All C entry points are internally thread-safe.
public actor LlamaEngine {
    private nonisolated let handle: OpaquePointer

    public init() {
        guard let h = llama_engine_create() else {
            fatalError("llama_engine_create returned null")
        }
        self.handle = h
    }

    deinit {
        llama_engine_destroy(handle)
    }

    public static func setLogLevel(_ level: LogLevel) {
        llama_engine_set_log_level(llama_engine_log_level(UInt32(level.rawValue)))
    }

    public nonisolated var state: EngineState {
        let raw = llama_engine_get_state(handle)
        return EngineState(rawValue: Int(raw.rawValue)) ?? .unloaded
    }

    /// Capabilities of the currently loaded model.
    ///
    /// Returns `.none` when the engine is unloaded; otherwise reflects:
    /// - the projector loaded at `load()` time (vision / audio),
    /// - the jinja chat template bundled with the model or provided via
    ///   `ModelConfig.chatTemplateOverride` (tool calls / reasoning).
    public var capabilities: EngineCapabilities {
        var c = llama_engine_capabilities()
        let status = llama_engine_get_capabilities(handle, &c)
        guard status == LLAMA_ENGINE_OK else { return .none }
        return EngineCapabilities(
            hasMultimodal:     c.has_mtmd,
            supportsVision:    c.supports_vision,
            supportsAudio:     c.supports_audio,
            supportsToolCalls: c.supports_tool_calls,
            supportsReasoning: c.supports_reasoning
        )
    }

    // MARK: - Lifecycle

    public func load(_ config: ModelConfig) throws {
        let status: llama_engine_status = config.withCConfig { cfg in
            llama_engine_load(handle, &cfg)
        }
        try throwIfError(status)
    }

    public func unload() throws {
        let status = llama_engine_unload(handle)
        try throwIfError(status)
    }

    /// Transition to `.sleeping`. Safe to call concurrently with an in-flight
    /// `load()` or `wake()` — the C core preempts the load via its progress
    /// callback and releases this function once the state has converged. The
    /// preempted `load()` / `wake()` call throws `LlamaError.cancelled`.
    public nonisolated func sleep() throws {
        let status = llama_engine_sleep(handle)
        try throwIfError(status)
    }

    public func wake() throws {
        let status = llama_engine_wake(handle)
        try throwIfError(status)
    }

    // MARK: - Tokenization

    public func tokenize(_ text: String, addSpecial: Bool = true) throws -> [Int32] {
        var outTokens: UnsafeMutablePointer<Int32>? = nil
        var outN: Int = 0
        let status = text.withCString { cstr in
            llama_engine_tokenize(handle, cstr, addSpecial, &outTokens, &outN)
        }
        try throwIfError(status)
        defer { llama_engine_free_tokens(outTokens) }
        guard let base = outTokens else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: outN))
    }

    public func detokenize(_ tokens: [Int32]) throws -> String {
        var outText: UnsafeMutablePointer<CChar>? = nil
        let status = tokens.withUnsafeBufferPointer { buf -> llama_engine_status in
            llama_engine_detokenize(handle, buf.baseAddress, buf.count, &outText)
        }
        try throwIfError(status)
        defer { llama_engine_free_string(outText) }
        return outText.map { String(cString: $0) } ?? ""
    }

    // MARK: - Chat completion (non-stream)

    /// `requestJSON` is an OpenAI-compatible chat-completion request.
    /// Returns the raw JSON response.
    public func chatCompletion(requestJSON: String) throws -> String {
        var outResp: UnsafeMutablePointer<CChar>? = nil
        let status = requestJSON.withCString { cstr in
            llama_engine_chat_completion(handle, cstr, &outResp)
        }
        let responseText = outResp.map { String(cString: $0) }
        llama_engine_free_string(outResp)

        if status == LLAMA_ENGINE_ERR_INFERENCE {
            let msg = lastErrorMessage() ?? "inference error"
            throw LlamaError.inference(msg, payload: responseText)
        }
        try throwIfError(status)
        return responseText ?? ""
    }

    // MARK: - Chat completion (stream)

    /// Streams chat-completion chunks as raw JSON strings.
    /// Each yielded string is one OAI chunk (no SSE framing, no `[DONE]`).
    /// Cancellation of the returned Task propagates via
    /// `llama_engine_stream_cancel`.
    public nonisolated func chatCompletionStream(requestJSON: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish(throwing: LlamaError.internalError("engine deallocated"))
                    return
                }
                await self.runStream(requestJSON: requestJSON, continuation: continuation)
            }
            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }

    private func runStream(
        requestJSON: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var stream: OpaquePointer? = nil
        let openStatus = requestJSON.withCString { cstr -> llama_engine_status in
            var rawPtr: OpaquePointer? = nil
            let s = llama_engine_chat_completion_stream(handle, cstr, &rawPtr)
            stream = rawPtr
            return s
        }

        if openStatus != LLAMA_ENGINE_OK {
            let msg = lastErrorMessage() ?? "failed to open stream"
            let err = map(status: openStatus, message: msg, payload: nil)
            continuation.finish(throwing: err)
            return
        }
        guard let streamPtr = stream else {
            continuation.finish(throwing: LlamaError.internalError("null stream handle"))
            return
        }

        defer {
            llama_engine_stream_close(streamPtr)
        }

        while !Task.isCancelled {
            var chunkPtr: UnsafeMutablePointer<CChar>? = nil
            var done = false
            let st = llama_engine_stream_next(streamPtr, &chunkPtr, &done)

            let chunk = chunkPtr.map { String(cString: $0) }
            llama_engine_free_string(chunkPtr)

            if st == LLAMA_ENGINE_ERR_INFERENCE {
                let msg = lastErrorMessage() ?? "inference error"
                continuation.finish(throwing: LlamaError.inference(msg, payload: chunk))
                return
            }
            if st == LLAMA_ENGINE_ERR_CANCELLED {
                continuation.finish(throwing: LlamaError.cancelled)
                return
            }
            if st != LLAMA_ENGINE_OK {
                let msg = lastErrorMessage() ?? "stream error"
                continuation.finish(throwing: map(status: st, message: msg, payload: chunk))
                return
            }

            if let c = chunk, !c.isEmpty {
                continuation.yield(c)
            }

            if done {
                continuation.finish()
                return
            }
        }

        // Task cancelled: signal cancel into the C stream and drain once.
        llama_engine_stream_cancel(streamPtr)
        continuation.finish(throwing: LlamaError.cancelled)
    }

    // MARK: - Internals

    private nonisolated func lastErrorMessage() -> String? {
        guard let cstr = llama_engine_last_error(handle) else { return nil }
        return String(cString: cstr)
    }

    private nonisolated func throwIfError(_ status: llama_engine_status) throws {
        if status == LLAMA_ENGINE_OK { return }
        throw map(status: status, message: lastErrorMessage() ?? "unknown error", payload: nil)
    }

    private nonisolated func map(status: llama_engine_status, message: String, payload: String?) -> LlamaError {
        switch status {
        case LLAMA_ENGINE_OK:                    return .internalError("map called on OK")
        case LLAMA_ENGINE_ERR_NOT_LOADED:        return .notLoaded
        case LLAMA_ENGINE_ERR_ALREADY_LOADED:    return .alreadyLoaded
        case LLAMA_ENGINE_ERR_LOAD_FAILED:       return .loadFailed(message)
        case LLAMA_ENGINE_ERR_INVALID_ARG:       return .invalidArgument(message)
        case LLAMA_ENGINE_ERR_INVALID_REQUEST:   return .invalidRequest(message)
        case LLAMA_ENGINE_ERR_INFERENCE:         return .inference(message, payload: payload)
        case LLAMA_ENGINE_ERR_CANCELLED:         return .cancelled
        case LLAMA_ENGINE_ERR_TIMEOUT:           return .timeout
        default:                                 return .internalError(message)
        }
    }
}

// MARK: - ModelConfig bridging

fileprivate extension ModelConfig {
    /// Convert to a `llama_engine_config` with all C strings kept alive for the
    /// duration of `body`.
    func withCConfig<R>(_ body: (inout llama_engine_config) -> R) -> R {
        let path = modelPath.path
        let mtmd = mtmdProjectorPath?.path
        let tmpl = chatTemplateOverride
        let extra = extraJSON

        return path.withCString { cPath in
            return (mtmd ?? "").withCString { cMtmd in
                return (tmpl ?? "").withCString { cTmpl in
                    return (extra ?? "").withCString { cExtra in
                        var cfg = llama_engine_config(
                            model_path: cPath,
                            context_size: contextSize,
                            gpu_layers: gpuLayers,
                            parallel_slots: parallelSlots,
                            cpu_threads: cpuThreads,
                            seed: seed,
                            mtmd_projector_path: (mtmd?.isEmpty == false) ? cMtmd : nil,
                            chat_template_override: (tmpl?.isEmpty == false) ? cTmpl : nil,
                            use_mmap: useMMap,
                            use_mlock: useMlock,
                            flash_attention: flashAttention,
                            kv_cache_type: llama_engine_kv_type(UInt32(kvCacheType.rawValue)),
                            idle_sleep_seconds: idleSleepSeconds,
                            extra_json: (extra?.isEmpty == false) ? cExtra : nil
                        )
                        return body(&cfg)
                    }
                }
            }
        }
    }
}
