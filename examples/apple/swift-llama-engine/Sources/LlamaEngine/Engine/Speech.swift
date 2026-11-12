import Foundation
import LlamaEngineCore

/// A speech generation request, the `/tts` body of llama-server.
///
/// Check ``EngineOperations/speechGeneration`` before using it.
public struct SpeechRequest: Sendable, Hashable {
    /// The text to speak.
    public var input: String
    /// One of ``RuntimeModelCapabilities/voices``; nil for the model default.
    /// Cannot be used with ``speakerReference``.
    public var voice: String?
    /// The language of the speech, e.g. `"French"`; nil for the model default.
    public var language: String?
    /// A WAV or MP3 clip of the voice to clone. Needs
    /// ``RuntimeModelCapabilities/audioSpeakerReference``.
    public var speakerReference: Data?
    public var seed: Int?
    public var temperature: Double?
    /// The maximum number of generated tokens.
    public var maxTokens: Int?

    public init(input: String,
                voice: String? = nil,
                language: String? = nil,
                speakerReference: Data? = nil,
                seed: Int? = nil,
                temperature: Double? = nil,
                maxTokens: Int? = nil) {
        self.input = input
        self.voice = voice
        self.language = language
        self.speakerReference = speakerReference
        self.seed = seed
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    func json() throws -> String {
        var body: [String: Any] = ["input": input]
        if let voice { body["voice"] = voice }
        if let language { body["lang"] = language }
        if let speakerReference { body["speaker_ref_b64"] = speakerReference.base64EncodedString() }
        if let seed { body["seed"] = seed }
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["n_predict"] = maxTokens }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Mono PCM audio, Float samples in [-1, 1].
public struct SpeechAudio: Sendable, Hashable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Takes the samples of `audio` and frees it.
    init(taking audio: inout llama_engine_audio) {
        samples = audio.samples.map { Array(UnsafeBufferPointer(start: $0, count: audio.n_samples)) } ?? []
        sampleRate = Double(audio.sample_rate)
        llama_engine_free_audio(&audio)
    }
}

/// Single-consumer stream of speech audio chunks produced by `LlamaEngine`.
///
/// The stream owns the underlying C stream handle. `cancel()` is idempotent and
/// crosses the C seam immediately; `deinit` always closes the handle.
public final class SpeechStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = SpeechAudio

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let stream: SpeechStream?
        private let alreadyConsumed: Bool

        init(stream: SpeechStream?, alreadyConsumed: Bool) {
            self.stream = stream
            self.alreadyConsumed = alreadyConsumed
        }

        public mutating func next() async throws -> SpeechAudio? {
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
        let alreadyConsumed = stateLock.withLock {
            defer { consumed = true }
            return consumed
        }
        return AsyncIterator(stream: self, alreadyConsumed: alreadyConsumed)
    }

    /// Requests cancellation of the underlying generation. Safe to call more
    /// than once and from any thread.
    public func cancel() {
        let h = stateLock.withLock {
            cancelled = true
            return handle
        }
        if let h {
            llama_engine_stream_cancel(h)
        }
    }

    private func close() {
        let h = stateLock.withLock {
            defer { handle = nil }
            cancelled = true
            finished = true
            return handle
        }
        if let h {
            llama_engine_stream_close(h)
        }
    }

    private func next() async throws -> SpeechAudio? {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try self.nextBlocking()
            }.value
        } onCancel: {
            self.cancel()
        }
    }

    private func nextBlocking() throws -> SpeechAudio? {
        nextLock.lock()
        defer { nextLock.unlock() }

        let h: OpaquePointer? = try stateLock.withLock {
            if finished { return nil }
            if cancelled { throw LlamaError.cancelled }
            return handle
        }
        guard let h else { return nil }

        var chunk = llama_engine_audio()
        var done = false
        let status = llama_engine_speech_stream_next(h, &chunk, &done)
        let audio = SpeechAudio(taking: &chunk)

        if done {
            stateLock.withLock { finished = true }
        }
        if status == LLAMA_ENGINE_ERR_CANCELLED {
            throw LlamaError.cancelled
        }
        if status != LLAMA_ENGINE_OK {
            let msg = engine.lastErrorMessage() ?? "speech stream error"
            throw engine.map(status: status, message: msg, payload: nil)
        }
        return done ? nil : audio
    }
}
