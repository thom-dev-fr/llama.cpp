import Foundation
import LlamaEngineCore

/// Actor-isolated façade over the C engine. All lifecycle operations are
/// serialised; chat completion streams are detached so multiple requests can
/// run concurrently while the actor handles load/unload/sleep/wake.
public actor LlamaEngine {
    private var handle: OpaquePointer?

    public init() {
        self.handle = llama_engine_create()
    }

    deinit {
        if let h = handle {
            llama_engine_destroy(h)
        }
    }

    public static func setLogLevel(_ level: LogLevel) {
        llama_engine_set_log_level(llama_engine_log_level(UInt32(level.rawValue)))
    }

    public var state: EngineState {
        guard let h = handle else { return .unloaded }
        let raw = llama_engine_get_state(raw(h))
        return EngineState(rawValue: Int(raw.rawValue)) ?? .unloaded
    }

    /// Capabilities of the currently loaded model.
    ///
    /// Returns `.none` when the engine is unloaded; otherwise reflects:
    /// - the projector loaded at `load()` time (vision / audio),
    /// - the jinja chat template bundled with the model or provided via
    ///   `ModelConfig.chatTemplateOverride` (tool calls / reasoning).
    public var capabilities: EngineCapabilities {
        guard let h = handle else { return .none }
        var c = llama_engine_capabilities()
        let status = llama_engine_get_capabilities(raw(h), &c)
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
        guard let h = handle else { throw LlamaError.internalError("engine pointer is nil") }

        let status: llama_engine_status = config.withCConfig { cfg in
            llama_engine_load(raw(h), &cfg)
        }
        try throwIfError(status, lastErrorHandle: h)
    }

    public func unload() throws {
        guard let h = handle else { return }
        let status = llama_engine_unload(raw(h))
        try throwIfError(status, lastErrorHandle: h)
    }

    public func sleep() throws {
        guard let h = handle else { throw LlamaError.notLoaded }
        let status = llama_engine_sleep(raw(h))
        try throwIfError(status, lastErrorHandle: h)
    }

    public func wake() throws {
        guard let h = handle else { throw LlamaError.notLoaded }
        let status = llama_engine_wake(raw(h))
        try throwIfError(status, lastErrorHandle: h)
    }

    // MARK: - Tokenization

    public func tokenize(_ text: String, addSpecial: Bool = true) throws -> [Int32] {
        guard let h = handle else { throw LlamaError.notLoaded }
        var outTokens: UnsafeMutablePointer<Int32>? = nil
        var outN: Int = 0
        let status = text.withCString { cstr in
            llama_engine_tokenize(raw(h), cstr, addSpecial, &outTokens, &outN)
        }
        try throwIfError(status, lastErrorHandle: h)
        defer { llama_engine_free_tokens(outTokens) }
        guard let base = outTokens else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: outN))
    }

    public func detokenize(_ tokens: [Int32]) throws -> String {
        guard let h = handle else { throw LlamaError.notLoaded }
        var outText: UnsafeMutablePointer<CChar>? = nil
        let status = tokens.withUnsafeBufferPointer { buf -> llama_engine_status in
            llama_engine_detokenize(raw(h), buf.baseAddress, buf.count, &outText)
        }
        try throwIfError(status, lastErrorHandle: h)
        defer { llama_engine_free_string(outText) }
        return outText.map { String(cString: $0) } ?? ""
    }

    // MARK: - Chat completion (non-stream)

    /// `requestJSON` is an OpenAI-compatible chat-completion request.
    /// Returns the raw JSON response.
    public func chatCompletion(requestJSON: String) throws -> String {
        guard let h = handle else { throw LlamaError.notLoaded }
        var outResp: UnsafeMutablePointer<CChar>? = nil
        let status = requestJSON.withCString { cstr in
            llama_engine_chat_completion(raw(h), cstr, &outResp)
        }
        let responseText = outResp.map { String(cString: $0) }
        llama_engine_free_string(outResp)

        if status == LLAMA_ENGINE_ERR_INFERENCE {
            let msg = lastError(h) ?? "inference error"
            throw LlamaError.inference(msg, payload: responseText)
        }
        try throwIfError(status, lastErrorHandle: h)
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
        guard let h = handle else {
            continuation.finish(throwing: LlamaError.notLoaded)
            return
        }

        var stream: OpaquePointer? = nil
        let openStatus = requestJSON.withCString { cstr -> llama_engine_status in
            var raw: OpaquePointer? = nil
            let s = llama_engine_chat_completion_stream(self.raw(h), cstr, &raw)
            stream = raw
            return s
        }

        if openStatus != LLAMA_ENGINE_OK {
            let msg = lastError(h) ?? "failed to open stream"
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
                let msg = lastError(h) ?? "inference error"
                continuation.finish(throwing: LlamaError.inference(msg, payload: chunk))
                return
            }
            if st == LLAMA_ENGINE_ERR_CANCELLED {
                continuation.finish(throwing: LlamaError.cancelled)
                return
            }
            if st != LLAMA_ENGINE_OK {
                let msg = lastError(h) ?? "stream error"
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

    private func raw(_ h: OpaquePointer) -> OpaquePointer {
        return h
    }

    private func lastError(_ h: OpaquePointer) -> String? {
        guard let cstr = llama_engine_last_error(raw(h)) else { return nil }
        return String(cString: cstr)
    }

    private func throwIfError(_ status: llama_engine_status, lastErrorHandle h: OpaquePointer) throws {
        if status == LLAMA_ENGINE_OK { return }
        throw map(status: status, message: lastError(h) ?? "unknown error", payload: nil)
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
