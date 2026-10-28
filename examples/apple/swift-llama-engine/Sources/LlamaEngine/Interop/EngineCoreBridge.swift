import Foundation
import LlamaEngineCore

extension LlamaEngine {
    func loadSync(_ config: ModelConfig) throws {
        let status: llama_engine_status = config.withCConfig { cfg in
            llama_engine_load(handle, &cfg)
        }
        try throwIfError(status)
    }

    func unloadSync() throws {
        let status = llama_engine_unload(handle)
        try throwIfError(status)
    }

    func pauseSync() throws {
        let status = llama_engine_pause(handle)
        try throwIfError(status)
    }

    func resumeSync() throws {
        let status = llama_engine_resume(handle)
        try throwIfError(status)
    }

    func tokenizeSync(_ text: String, addSpecial: Bool = true) throws -> [Int32] {
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

    func detokenizeSync(_ tokens: [Int32]) throws -> String {
        var outText: UnsafeMutablePointer<CChar>? = nil
        let status = tokens.withUnsafeBufferPointer { buf -> llama_engine_status in
            llama_engine_detokenize(handle, buf.baseAddress, buf.count, &outText)
        }
        try throwIfError(status)
        defer { llama_engine_free_string(outText) }
        return outText.map { String(cString: $0) } ?? ""
    }

    func countChatTokensSync(requestJSON: String) throws -> String {
        var outResp: UnsafeMutablePointer<CChar>? = nil
        let status = requestJSON.withCString { cstr in
            llama_engine_count_chat_tokens(handle, cstr, &outResp)
        }
        let responseText = outResp.map { String(cString: $0) }
        llama_engine_free_string(outResp)

        try throwIfError(status)
        return responseText ?? ""
    }

    func chatCompletionSync(requestJSON: String) throws -> String {
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

    func openChatCompletionStreamSync(requestJSON: String) throws -> EngineStream {
        var rawPtr: OpaquePointer? = nil
        let status = requestJSON.withCString { cstr in
            llama_engine_chat_completion_stream(handle, cstr, &rawPtr)
        }

        if status != LLAMA_ENGINE_OK {
            let msg = lastErrorMessage() ?? "failed to open stream"
            throw map(status: status, message: msg, payload: nil)
        }
        guard let streamHandle = rawPtr else {
            throw LlamaError.internalError("null stream handle")
        }
        return EngineStream(engine: self, handle: streamHandle)
    }

    func capabilitiesSync() throws -> EngineCapabilities {
        var outJSON: UnsafeMutablePointer<CChar>? = nil
        let status = llama_engine_get_capabilities(handle, &outJSON)
        let json = outJSON.map { String(cString: $0) }
        llama_engine_free_string(outJSON)

        try throwIfError(status)
        guard let json else { throw LlamaError.internalError("empty capabilities document") }
        return try EngineCapabilities(json: json)
    }

    static func chatCapabilitiesSync(for config: ModelConfig) throws -> EngineCapabilities {
        var outJSON: UnsafeMutablePointer<CChar>? = nil
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let status = config.withCConfig { cfg in
            llama_engine_probe_chat_capabilities(&cfg, &outJSON, &errPtr)
        }
        let json = outJSON.map { String(cString: $0) }
        let message = errPtr.map { String(cString: $0) }
        llama_engine_free_string(outJSON)
        llama_engine_free_string(errPtr)

        if status != LLAMA_ENGINE_OK {
            throw LlamaError.invalidArgument(message ?? "chat capabilities probe failed")
        }
        guard let json else { throw LlamaError.internalError("empty capabilities document") }
        return try EngineCapabilities(json: json)
    }

    static func measureMemorySync(for config: ModelConfig) throws -> NativeMemoryReport {
        var outJSON: UnsafeMutablePointer<CChar>? = nil
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let status = config.withCConfig { cfg in
            llama_engine_measure_memory(&cfg, &outJSON, &errPtr)
        }
        let json = outJSON.map { String(cString: $0) }
        let message = errPtr.map { String(cString: $0) } ?? "memory measurement failed"
        llama_engine_free_string(outJSON)
        llama_engine_free_string(errPtr)

        switch status {
        case LLAMA_ENGINE_OK:
            guard let json else { throw LlamaError.internalError("empty memory report") }
            return try NativeMemoryReport(json: json)
        case LLAMA_ENGINE_ERR_INVALID_ARG:
            throw LlamaError.invalidArgument(message)
        case LLAMA_ENGINE_ERR_LOAD_FAILED:
            throw LlamaError.loadFailed(message)
        default:
            throw LlamaError.internalError(message)
        }
    }

    func lastErrorMessage() -> String? {
        guard let cstr = llama_engine_last_error(handle) else { return nil }
        return String(cString: cstr)
    }

    func throwIfError(_ status: llama_engine_status) throws {
        if status == LLAMA_ENGINE_OK { return }
        throw map(status: status, message: lastErrorMessage() ?? "unknown error", payload: nil)
    }

    func map(status: llama_engine_status, message: String, payload: String?) -> LlamaError {
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
