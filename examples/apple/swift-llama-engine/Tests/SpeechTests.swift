import Foundation
import LlamaEngineCore
import Testing
@testable import LlamaEngine

struct SpeechRequestTests {
    @Test func encodesOnlyTheGivenFields() throws {
        #expect(try SpeechRequest(input: "Hello").json() == #"{"input":"Hello"}"#)

        let full = SpeechRequest(input: "Bonjour", voice: "alice", language: "French",
                                 speakerReference: Data([1, 2, 3]), speakerReferenceText: "Salut",
                                 seed: 7, temperature: 0.5, maxTokens: 300, cfgScale: 1.5, flowSteps: 16)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(full.json().utf8)) as? [String: Any])
        #expect(body["input"] as? String == "Bonjour")
        #expect(body["voice"] as? String == "alice")
        #expect(body["lang"] as? String == "French")
        #expect(body["speaker_ref_b64"] as? String == "AQID")
        #expect(body["seed"] as? Int == 7)
        #expect(body["temperature"] as? Double == 0.5)
        #expect(body["n_predict"] as? Int == 300)
        #expect(body["speaker_ref_text"] as? String == "Salut")
        #expect(body["cfg_scale"] as? Double == 1.5)
        #expect(body["flow_steps"] as? Int == 16)
        // the engine sets them
        #expect(body["response_format"] == nil)
        #expect(body["stream"] == nil)
    }
}

struct SpeechAudioTests {
    private static func cAudio(_ samples: [Float], rate: Int32, channels: Int32) -> llama_engine_audio {
        let buffer = malloc(samples.count * MemoryLayout<Float>.stride)!.assumingMemoryBound(to: Float.self)
        buffer.initialize(from: samples, count: samples.count)
        return llama_engine_audio(samples: buffer, n_samples: samples.count, sample_rate: rate, n_channels: channels)
    }

    @Test func takesInterleavedStereo() {
        var audio = Self.cAudio([0.1, -0.1, 0.2, -0.2, 0.3, -0.3], rate: 44_100, channels: 2)
        let taken = SpeechAudio(taking: &audio)
        #expect(taken.channelCount == 2)
        #expect(taken.frameCount == 3)
        #expect(taken.samples == [0.1, -0.1, 0.2, -0.2, 0.3, -0.3])
        #expect(taken.sampleRate == 44_100)
        #expect(audio.samples == nil && audio.n_samples == 0)
    }

    @Test func treatsAZeroedStructAsMono() {
        var empty = llama_engine_audio()
        let taken = SpeechAudio(taking: &empty)
        #expect(taken.samples.isEmpty)
        #expect(taken.channelCount == 1)
        #expect(taken.frameCount == 0)
        #expect(SpeechAudio(samples: [0, 0], sampleRate: 24_000).channelCount == 1)
    }
}

/// Opt-in: same model as the realtime tests (LFM3-Omni-2B speaks), in the
/// same serialized suite since two model loads cannot run at once.
extension RealtimeSessionModelTests {
    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func generatesTheSameSpeechBlockingAndStreamed() async throws {
        let engine = try await Self.loadedEngine()
        #expect(try await engine.capabilities().engineOperations?.speechGeneration == true)

        let request = SpeechRequest(input: "Hello, this is a short test of the speech output.", seed: 42)
        let audio = try await engine.generateSpeech(request)
        #expect(audio.sampleRate == 24_000)
        #expect(audio.channelCount == 1)
        // at least half a second of voice; the quality is checked by ear
        #expect(Double(audio.samples.count) >= audio.sampleRate / 2)
        #expect(audio.samples.allSatisfy { $0.isFinite && abs($0) <= 1.5 })

        var streamed: [Float] = []
        var chunks = 0
        for try await chunk in try await engine.speechStream(request) {
            #expect(chunk.sampleRate == audio.sampleRate)
            streamed += chunk.samples
            chunks += 1
        }
        #expect(chunks > 1)
        #expect(streamed.count == audio.samples.count)
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func cancelsAStreamAndRefusesDuringARealtimeSession() async throws {
        let engine = try await Self.loadedEngine()
        let request = SpeechRequest(input: "This sentence is long enough to be cancelled before its end.", seed: 1)

        do {
            let stream = try await engine.speechStream(request)
            var iterator = stream.makeAsyncIterator()
            #expect(try await iterator.next() != nil)
            stream.cancel()
            await #expect(throws: LlamaError.self) {
                while try await iterator.next() != nil {}
            }
        }
        // the stream is closed once released, like a chat stream

        let session = try await engine.openRealtimeSession()
        do {
            _ = try await engine.generateSpeech(request)
            Issue.record("speech must be refused while a session is open")
        } catch LlamaError.busy {
        }
        session.close()
        for try await _ in session {}

        await #expect(throws: LlamaError.self) {
            _ = try await engine.generateSpeech(SpeechRequest(input: ""))
        }
    }
}
