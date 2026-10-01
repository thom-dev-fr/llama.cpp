import Foundation
@testable import LlamaEngine
@testable import LlamaFoundationModels

/// A controlled engine boundary: the real adapter runs against scripted
/// engine events and every submitted request is recorded.
final class ScriptedBackend: LlamaChatBackend, @unchecked Sendable {
    /// One engine answer: events in order, then an optional terminal failure.
    struct Script {
        var events: [NativeEvent] = []
        var failure: (any Error)?
        /// Never ends by itself: the reader waits until cancelled.
        var hangs = false
        /// Thrown by the submission itself (admission, load).
        var submitError: (any Error)?
    }

    struct Submission {
        var body: Data
        var attachments: [NativeAttachment]
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var recorded: [Submission] = []
    private var streams: [ScriptedEvents] = []
    var artifacts: [LlamaModelID: LlamaModelArtifact] = [:]
    var properties: Data = Data(#"{"chat_template_caps":{"supports_reasoning_effort":false}}"#.utf8)
    private(set) var propertyRequests = 0

    init(_ scripts: [Script] = []) {
        self.scripts = scripts
    }

    func enqueue(_ script: Script) {
        lock.withLock { scripts.append(script) }
    }

    var submissions: [Submission] { lock.withLock { recorded } }
    var cancelledStreams: Int { lock.withLock { streams.filter(\.wasCancelled).count } }

    func artifact(_ id: LlamaModelID) -> LlamaModelArtifact? {
        lock.withLock { artifacts[id] }
    }

    func chat(model: LlamaModelID, profile: LlamaLoadProfile, body: Data,
              attachments: [NativeAttachment]) async throws -> any LlamaChatEvents {
        let script: Script = lock.withLock {
            recorded.append(Submission(body: body, attachments: attachments))
            return scripts.isEmpty ? Script(events: [.success]) : scripts.removeFirst()
        }
        if let error = script.submitError {
            throw error
        }
        let events = ScriptedEvents(script)
        lock.withLock { streams.append(events) }
        return events
    }

    func properties(model: LlamaModelID, profile: LlamaLoadProfile) async throws -> Data {
        lock.withLock {
            propertyRequests += 1
            return properties
        }
    }
}

final class ScriptedEvents: LlamaChatEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [NativeEvent]
    private let failure: (any Error)?
    private let hangs: Bool
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ script: ScriptedBackend.Script) {
        pending = script.events
        failure = script.failure
        hangs = script.hangs
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func next() async throws -> NativeEvent? {
        if let event: NativeEvent = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) {
            return event
        }
        if hangs {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock { () -> Bool in
                        if cancelled { return true }
                        waiter = continuation
                        return false
                    }
                    if resume { continuation.resume() }
                }
            } onCancel: {
                cancel()
            }
            throw LlamaEngineError.native(category: "cancelled", message: "cancelled", details: Data("null".utf8))
        }
        if let failure {
            throw failure
        }
        return nil
    }

    func cancel() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            cancelled = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

// MARK: - Engine payloads

extension NativeEvent {
    static var success: NativeEvent { NativeEvent(kind: .success, data: Data("null".utf8), category: "", message: "") }

    static func payload(_ json: String) -> NativeEvent {
        NativeEvent(kind: .payload, data: Data(json.utf8), category: "", message: "")
    }

    static func context(prompt: Int, cached: Int = 0, decoded: Int, reasoning: Int = 0, size: Int = 4096) -> String {
        #"{"n_ctx":\#(size),"n_tokens":\#(prompt + decoded),"n_prompt_tokens":\#(prompt),"n_cache_tokens":\#(cached),"n_decoded":\#(decoded),"n_reasoning_tokens":\#(reasoning)}"#
    }

    /// A chat chunk with a delta (JSON object members) and a context report.
    static func delta(_ delta: String, decoded: Int, prompt: Int = 10, reasoning: Int = 0, finish: String? = nil) -> NativeEvent {
        let finishJSON = finish.map { "\"\($0)\"" } ?? "null"
        return payload(#"{"choices":[{"index":0,"finish_reason":\#(finishJSON),"delta":{\#(delta)}}],"context":\#(context(prompt: prompt, decoded: decoded, reasoning: reasoning))}"#)
    }

    static func text(_ text: String, decoded: Int) -> NativeEvent {
        delta(#""content":\#(jsonString(text))"#, decoded: decoded)
    }

    static func reasoning(_ text: String, decoded: Int) -> NativeEvent {
        delta(#""reasoning_content":\#(jsonString(text))"#, decoded: decoded, reasoning: decoded)
    }

    static func toolCall(index: Int, id: String? = nil, name: String? = nil, arguments: String, decoded: Int) -> NativeEvent {
        var call = #""index":\#(index)"#
        if let id { call += #","id":"\#(id)","type":"function""# }
        var function = #""arguments":\#(jsonString(arguments))"#
        if let name { function = #""name":"\#(name)","# + function }
        return delta(#""tool_calls":[{\#(call),"function":{\#(function)}}]"#, decoded: decoded)
    }

    static func finish(_ reason: String, decoded: Int, prompt: Int = 10, reasoning: Int = 0) -> NativeEvent {
        delta("", decoded: decoded, prompt: prompt, reasoning: reasoning, finish: reason)
    }

    static func progress(processed: Int, total: Int) -> NativeEvent {
        payload(#"{"choices":[{"index":0,"finish_reason":null,"delta":{"role":"assistant","content":null}}],"context":\#(context(prompt: total, decoded: 0)),"prompt_progress":{"total":\#(total),"cache":0,"processed":\#(processed),"time_ms":1}}"#)
    }
}

func jsonString(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
}

/// A context overflow as the engine reports it (fail_on_context_full).
func contextOverflow(phase: String, prompt: Int, decoded: Int, size: Int) -> LlamaEngineError {
    let data = Data(#"{"code":400,"message":"the context is full","type":"exceed_context_size_error","n_prompt_tokens":\#(prompt),"n_ctx":\#(size),"context_phase":"\#(phase)","n_decoded":\#(decoded)}"#.utf8)
    return .contextExceeded(LlamaContextOverflow(errorData: data)!)
}
