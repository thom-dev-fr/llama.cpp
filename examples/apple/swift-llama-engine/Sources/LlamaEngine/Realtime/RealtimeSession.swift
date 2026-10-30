import AVFoundation
import Foundation
import LlamaEngineCore

/// What a realtime session is opened for.
public enum RealtimeSessionIntent: Sendable, Hashable {
    /// A conversation for models with ``RuntimeModelCapabilities/realtimeConversation``,
    /// or the live transcription of a model that only has `audio_stream`.
    case conversation
    /// A live transcription session, for models that can also hold a conversation.
    case transcription
}

/// An output modality of a realtime response.
public enum RealtimeModality: String, Sendable, Hashable {
    case text
    case audio
}

/// A function the model may call in a realtime conversation.
public struct RealtimeTool: Sendable, Hashable {
    public let name: String
    public let description: String
    /// The JSON schema of the arguments, as JSON text.
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Whether the model may, must or must not call the tools of the session.
public enum RealtimeToolChoice: String, Sendable, Hashable {
    case auto
    case none
    case required
}

/// Owns the C handle. A read in progress keeps it alive, so the handle is
/// never freed under `llama_engine_realtime_next`.
final class RealtimeHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        llama_engine_realtime_free(pointer)
    }

    func close() {
        llama_engine_realtime_close(pointer)
    }
}

/// A realtime session of a ``LlamaEngine``: the `/v1/realtime` protocol of
/// llama-server, without any socket.
///
/// Iterate the session for the server events, and send client events with
/// the methods below from any thread. The events are read on the session's
/// own thread, one at a time as the consumer asks for them: a consumer that
/// stops reading ends the session with an `output_queue_full` error instead of
/// growing memory.
///
/// ```swift
/// let session = try await engine.openRealtimeSession()
/// try session.updateSession(instructions: "Answer in one sentence.", outputModalities: [.text])
/// try session.appendAudio(samples, sampleRate: 48_000)
/// try session.commitAudio()
/// try session.createResponse()
/// for try await event in session {
///     if let text = event.textDelta { print(text, terminator: "") }
///     if event.type == "response.done" { break }
/// }
/// session.close()
/// ```
///
/// ``close()`` ends the session; to stop a response and keep the
/// conversation, use ``cancelResponse()``. Cancelling the task that iterates
/// the session also closes it. Pause, unload and the end of the engine close
/// it with a last `error` event whose ``RealtimeEventError/code`` is
/// `session_terminated`; the session object stays safe to use after that.
public final class RealtimeSession: AsyncSequence, @unchecked Sendable {
    public typealias Element = RealtimeEvent

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let session: RealtimeSession?
        private let alreadyConsumed: Bool

        init(session: RealtimeSession?, alreadyConsumed: Bool) {
            self.session = session
            self.alreadyConsumed = alreadyConsumed
        }

        public mutating func next() async throws -> RealtimeEvent? {
            if alreadyConsumed {
                throw LlamaError.streamAlreadyConsumed
            }
            guard let session else { return nil }
            return try await session.next()
        }
    }

    /// Largest audio chunk per `input_audio_buffer.append`, in seconds.
    static let maxAppendSeconds = 1.0

    private let handle: RealtimeHandle
    private let readQueue = DispatchQueue(label: "llama-engine.realtime.reader", qos: .userInitiated)
    private let stateLock = NSLock()
    private let sendLock = NSLock()

    private var consumed = false
    private var finished = false
    private var inputRate: Double = 16_000
    private var outputRate: Double = 24_000
    private var audioOutput = false
    private var resampler: RealtimeAudioResampler? // guarded by sendLock
    private var firstEvent: Result<RealtimeEvent?, Error>? // read at open, given to the first next()

    init(handle: OpaquePointer) {
        self.handle = RealtimeHandle(handle)
    }

    deinit {
        handle.close()
    }

    /// The sample rate of the input audio, from `session.created`, known
    /// once the session is open. ``appendAudio(_:sampleRate:)`` resamples to it.
    public var inputSampleRate: Double {
        stateLock.withLock { inputRate }
    }

    /// The sample rate of ``RealtimeEvent/audio``, from `session.created`.
    public var outputSampleRate: Double {
        stateLock.withLock { outputRate }
    }

    /// True when the session can answer with ``RealtimeModality/audio``:
    /// `session.created` announces an `audio.output` format. Known once the
    /// session is open; always false for a transcription session.
    public var supportsAudioOutput: Bool {
        stateLock.withLock { audioOutput }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let alreadyConsumed = stateLock.withLock {
            defer { consumed = true }
            return consumed
        }
        return AsyncIterator(session: self, alreadyConsumed: alreadyConsumed)
    }

    /// Ends the session. The events already sent can still be read, then the
    /// iteration ends. Idempotent, safe from any thread, does not block.
    public func close() {
        handle.close()
    }

    // MARK: - Client events

    /// Sends one client event as JSON text.
    ///
    /// Throws ``LlamaError/invalidArgument(_:)`` for an event over 2 MiB and
    /// ``LlamaError/cancelled`` once the session has ended. A bad event is
    /// answered by an `error` event, the session stays open.
    public func send(json: String) throws {
        try sendLock.withLock { try sendLocked(json) }
    }

    /// Sends `session.update`. Instructions, tools and type can only change
    /// before the first audio or message.
    ///
    /// Throws ``LlamaError/invalidArgument(_:)`` if the parameters of a tool
    /// are not a JSON object.
    public func updateSession(instructions: String? = nil,
                              outputModalities: [RealtimeModality]? = nil,
                              maxOutputTokens: Int? = nil,
                              tools: [RealtimeTool]? = nil,
                              toolChoice: RealtimeToolChoice? = nil) throws {
        var session: [String: Any] = [:]
        if let instructions { session["instructions"] = instructions }
        if let outputModalities { session["output_modalities"] = outputModalities.map(\.rawValue) }
        if let maxOutputTokens { session["max_output_tokens"] = maxOutputTokens }
        if let tools { session["tools"] = try tools.map(Self.toolObject) }
        if let toolChoice { session["tool_choice"] = toolChoice.rawValue }
        try send(["type": "session.update", "session": session])
    }

    /// Appends audio of the user turn, resampled to ``inputSampleRate``.
    public func appendAudio(_ samples: [Float], sampleRate: Double) throws {
        try sendLock.withLock {
            let converted = try resamplerLocked().convert(samples, sampleRate: sampleRate)
            try appendLocked(converted)
        }
    }

    /// Appends audio of the user turn, e.g. from an `AVAudioEngine` tap.
    /// Channels are mixed down and the audio is resampled to ``inputSampleRate``.
    public func appendAudio(_ buffer: AVAudioPCMBuffer) throws {
        try sendLock.withLock {
            let converted = try resamplerLocked().convert(buffer)
            try appendLocked(converted)
        }
    }

    /// Ends the audio of the user turn.
    public func commitAudio() throws {
        try sendLock.withLock {
            if let resampler {
                try appendLocked(try resampler.flush())
            }
            try sendLocked(Self.json(["type": "input_audio_buffer.commit"]))
        }
    }

    /// Drops the audio appended since the last commit.
    public func clearAudio() throws {
        try sendLock.withLock {
            resampler = nil
            try sendLocked(Self.json(["type": "input_audio_buffer.clear"]))
        }
    }

    /// Adds a user text message to the conversation.
    public func addUserText(_ text: String) throws {
        try send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
    }

    /// Ends the user turn and starts the response.
    ///
    /// A response in progress must be cancelled first, else the event is
    /// refused with a `conversation_already_has_active_response` error.
    /// `eventID` is echoed in ``RealtimeEventError/eventID`` when the event
    /// is refused.
    public func createResponse(outputModalities: [RealtimeModality]? = nil,
                               maxOutputTokens: Int? = nil,
                               toolChoice: RealtimeToolChoice? = nil,
                               eventID: String? = nil) throws {
        var response: [String: Any] = [:]
        if let outputModalities { response["output_modalities"] = outputModalities.map(\.rawValue) }
        if let maxOutputTokens { response["max_output_tokens"] = maxOutputTokens }
        if let toolChoice { response["tool_choice"] = toolChoice.rawValue }
        var event: [String: Any] = ["type": "response.create"]
        if let eventID { event["event_id"] = eventID }
        if !response.isEmpty { event["response"] = response }
        try send(event)
    }

    /// Sends the result of a tool call of the last response. The next
    /// ``createResponse(outputModalities:maxOutputTokens:toolChoice:eventID:)``
    /// answers it.
    public func sendFunctionCallOutput(callID: String, output: String) throws {
        try send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output],
        ])
    }

    /// Stops the response being generated; the conversation goes on.
    public func cancelResponse() throws {
        try send(["type": "response.cancel"])
    }

    // MARK: - Internals

    private static func toolObject(_ tool: RealtimeTool) throws -> [String: Any] {
        guard let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] else {
            throw LlamaError.invalidArgument("the parameters of the tool \(tool.name) are not a JSON object")
        }
        return ["type": "function", "name": tool.name, "description": tool.description, "parameters": parameters]
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ object: [String: Any]) throws {
        try send(json: Self.json(object))
    }

    private func sendLocked(_ json: String) throws {
        let status = json.withCString { llama_engine_realtime_send(handle.pointer, $0) }
        switch status {
        case LLAMA_ENGINE_OK:
            return
        case LLAMA_ENGINE_ERR_INVALID_ARG:
            throw LlamaError.invalidArgument("realtime event over the size limit")
        case LLAMA_ENGINE_ERR_CANCELLED:
            throw LlamaError.cancelled
        default:
            throw LlamaError.internalError("realtime send failed (\(status.rawValue))")
        }
    }

    private func resamplerLocked() throws -> RealtimeAudioResampler {
        let rate = inputSampleRate
        if let resampler, resampler.targetRate == rate {
            return resampler
        }
        let r = try RealtimeAudioResampler(targetRate: rate)
        resampler = r
        return r
    }

    private func appendLocked(_ samples: [Float]) throws {
        let chunk = Swift.max(1, Int(inputSampleRate * Self.maxAppendSeconds))
        var start = 0
        while start < samples.count {
            let end = Swift.min(start + chunk, samples.count)
            let pcm = RealtimePCM16.encode(Array(samples[start..<end]))
            try sendLocked(Self.json(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]))
            start = end
        }
    }

    private func next() async throws -> RealtimeEvent? {
        if Task.isCancelled {
            close()
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readQueue.async {
                    continuation.resume(with: Result { try self.nextBlocking() })
                }
            }
        } onCancel: { [handle] in
            handle.close()
        }
    }

    /// Reads `session.created` before the session is handed out, so the
    /// audio rates are known before the first append. The event still comes
    /// first from the iteration.
    func readFirstEvent() {
        let result = Result { try nextBlocking() }
        stateLock.withLock { firstEvent = result }
    }

    private func nextBlocking() throws -> RealtimeEvent? {
        let first: Result<RealtimeEvent?, Error>? = stateLock.withLock {
            defer { firstEvent = nil }
            return firstEvent
        }
        if let first {
            return try first.get()
        }
        if stateLock.withLock({ finished }) {
            return nil
        }

        var eventPtr: UnsafeMutablePointer<CChar>? = nil
        var done = false
        let status = llama_engine_realtime_next(handle.pointer, &eventPtr, &done)
        let json = eventPtr.map { String(cString: $0) }
        llama_engine_free_string(eventPtr)

        if status != LLAMA_ENGINE_OK {
            throw LlamaError.internalError("realtime next failed (\(status.rawValue))")
        }
        guard !done, let json else {
            stateLock.withLock { finished = true }
            return nil
        }

        let event = RealtimeEvent(json: json)
        if event.type == "session.created" || event.type == "session.updated" {
            updateRates(from: event)
        }
        return event
    }

    private func updateRates(from event: RealtimeEvent) {
        guard let audio = Self.audioFormats(of: event) else { return }
        stateLock.withLock {
            if let input = audio.inputRate, input > 0 { inputRate = input }
            if let output = audio.outputRate, output > 0 { outputRate = output }
            audioOutput = audio.outputRate != nil
        }
    }

    /// The audio rates of a `session.created` or `session.updated` event;
    /// `outputRate` is nil when the session has no audio output.
    static func audioFormats(of event: RealtimeEvent) -> (inputRate: Double?, outputRate: Double?)? {
        guard let session = event.object?["session"] as? [String: Any],
              let audio = session["audio"] as? [String: Any] else { return nil }
        let input  = ((audio["input"]  as? [String: Any])?["format"] as? [String: Any])?["rate"] as? Double
        let output = ((audio["output"] as? [String: Any])?["format"] as? [String: Any])?["rate"] as? Double
        return (input, output)
    }
}
