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
    /// The transcript of ``speakerReference``. Some models (e.g. Fish Audio
    /// S2 Pro, Qwen3-TTS) use it to clone the voice more closely, the others
    /// ignore it.
    public var speakerReferenceText: String?
    public var seed: Int?
    public var temperature: Double?
    /// The maximum number of generated audio frames; nil for the model limit.
    /// The generation usually stops earlier, at the end of the speech.
    public var maxTokens: Int?
    /// The classifier-free guidance scale of the audio codes, > 0, 1 disables
    /// it; nil for the model default. Only for models that support it (e.g.
    /// YuE2, MiniMax Music 3): the others refuse the request.
    public var cfgScale: Double?
    /// The steps of the flow-matching solver, 1...1024, fewer is faster and
    /// less accurate; nil for the model default. Only for models that support
    /// it, like ``cfgScale``.
    public var flowSteps: Int?

    public init(input: String,
                voice: String? = nil,
                language: String? = nil,
                speakerReference: Data? = nil,
                speakerReferenceText: String? = nil,
                seed: Int? = nil,
                temperature: Double? = nil,
                maxTokens: Int? = nil,
                cfgScale: Double? = nil,
                flowSteps: Int? = nil) {
        self.input = input
        self.voice = voice
        self.language = language
        self.speakerReference = speakerReference
        self.speakerReferenceText = speakerReferenceText
        self.seed = seed
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.cfgScale = cfgScale
        self.flowSteps = flowSteps
    }

    func json() throws -> String {
        var body: [String: Any] = ["input": input]
        if let voice { body["voice"] = voice }
        if let language { body["lang"] = language }
        if let speakerReference { body["speaker_ref_b64"] = speakerReference.base64EncodedString() }
        if let speakerReferenceText { body["speaker_ref_text"] = speakerReferenceText }
        if let seed { body["seed"] = seed }
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["n_predict"] = maxTokens }
        if let cfgScale { body["cfg_scale"] = cfgScale }
        if let flowSteps { body["flow_steps"] = flowSteps }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// PCM audio, Float samples in [-1, 1], channels interleaved.
///
/// Most speech models are mono; music models (e.g. YuE2, MiniMax Music 3)
/// can be stereo. A frame holds one sample of each channel.
public struct SpeechAudio: Sendable, Hashable {
    /// The samples of all channels, interleaved: `L R L R ...` in stereo.
    public var samples: [Float]
    public var sampleRate: Double
    /// 1 for mono, 2 for stereo.
    public var channelCount: Int

    /// The number of frames, `samples.count / channelCount`.
    public var frameCount: Int {
        channelCount > 0 ? samples.count / channelCount : 0
    }

    public init(samples: [Float], sampleRate: Double, channelCount: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Takes the samples of `audio` and frees it.
    init(taking audio: inout llama_engine_audio) {
        samples = audio.samples.map { Array(UnsafeBufferPointer(start: $0, count: audio.n_samples)) } ?? []
        sampleRate = Double(audio.sample_rate)
        // a zeroed struct (no audio) has no channel count
        channelCount = max(1, Int(audio.n_channels))
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
