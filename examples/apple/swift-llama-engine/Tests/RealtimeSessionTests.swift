import AVFoundation
import Foundation
import Testing
@testable import LlamaEngine

struct RealtimePCM16Tests {
    @Test func roundTripsAndClamps() {
        let data = RealtimePCM16.encode([0, 0.5, -0.5, 2, -2])
        #expect(data.count == 10)
        let back = RealtimePCM16.decode(data)
        #expect(back.count == 5)
        #expect(back[0] == 0)
        #expect(abs(back[1] - 0.5) < 0.001)
        #expect(abs(back[2] + 0.5) < 0.001)
        #expect(abs(back[3] - 1) < 0.001)
        #expect(abs(back[4] + 1) < 0.001)
    }

    @Test func isLittleEndian() {
        let data = RealtimePCM16.encode([1])
        #expect([UInt8](data) == [0xFF, 0x7F])
    }

    @Test func rejectsBadBase64() {
        #expect(RealtimePCM16.decodeBase64("not base64!") == nil)
    }
}

struct RealtimeEventTests {
    @Test func readsTextDeltas() {
        let e = RealtimeEvent(json: #"{"type":"response.output_text.delta","delta":"Par","event_id":"e1"}"#)
        #expect(e.type == "response.output_text.delta")
        #expect(e.textDelta == "Par")
        #expect(e.audio == nil)
        #expect(e.error == nil)

        let t = RealtimeEvent(json: #"{"type":"conversation.item.input_audio_transcription.delta","delta":"What"}"#)
        #expect(t.textDelta == "What")
    }

    @Test func decodesAudioDeltas() {
        let pcm = RealtimePCM16.encode([0.25, -0.25]).base64EncodedString()
        let e = RealtimeEvent(json: #"{"type":"response.output_audio.delta","delta":"\#(pcm)"}"#)
        #expect(e.audio?.count == 2)
        #expect(abs((e.audio?[0] ?? 0) - 0.25) < 0.001)
        #expect(e.textDelta == nil)
    }

    @Test func readsTheResponse() {
        let delta = RealtimeEvent(json: #"{"type":"response.output_text.delta","response_id":"resp_1","delta":"a"}"#)
        #expect(delta.responseID == "resp_1")
        #expect(delta.responseStatus == nil)

        let created = RealtimeEvent(json: #"{"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}"#)
        #expect(created.responseID == "resp_2")
        #expect(created.responseStatus == nil)

        let done = RealtimeEvent(json: #"{"type":"response.done","response":{"id":"resp_2","status":"cancelled"}}"#)
        #expect(done.responseID == "resp_2")
        #expect(done.responseStatus == "cancelled")

        #expect(RealtimeEvent(json: #"{"type":"session.created"}"#).responseID == nil)
    }

    @Test func readsErrors() {
        let terminal = RealtimeEvent(json: #"{"type":"error","error":{"type":"server_error","code":"session_terminated","message":"engine paused","param":null}}"#)
        #expect(terminal.error?.code == "session_terminated")
        #expect(terminal.error?.message == "engine paused")
        #expect(terminal.error?.isTerminal == true)

        let proto = RealtimeEvent(json: #"{"type":"error","error":{"type":"invalid_request_error","code":null,"message":"invalid JSON","param":null}}"#)
        #expect(proto.error?.code == nil)
        #expect(proto.error?.isTerminal == false)

        let refused = RealtimeEvent(json: #"{"type":"error","error":{"type":"conversation_already_has_active_response","code":null,"message":"busy","param":null,"event_id":"evt_1"}}"#)
        #expect(refused.error?.eventID == "evt_1")
        #expect(proto.error?.eventID == nil)
    }

    @Test func keepsUnknownEvents() {
        let json = #"{"type":"future.event","value":[1,2]}"#
        let e = RealtimeEvent(json: json)
        #expect(e.type == "future.event")
        #expect(e.json == json)
        #expect((e.object?["value"] as? [Int]) == [1, 2])
    }

    @Test func readsFunctionCalls() {
        let done = RealtimeEvent(json: #"""
        {"type":"response.output_item.done","response_id":"resp_1","output_index":0,"item":{"id":"item_1",\#
        "type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}
        """#)
        #expect(done.functionCall == RealtimeFunctionCall(responseID: "resp_1", itemID: "item_1", callID: "call_1",
                                                          name: "get_weather", arguments: #"{"city":"Paris"}"#))
        let message = RealtimeEvent(json: #"{"type":"response.output_item.done","item":{"type":"message"}}"#)
        #expect(message.functionCall == nil)
    }

    @Test func readsTheAudioFormatsOfTheSession() throws {
        let conversation = RealtimeEvent(json: #"{"type":"session.created","session":{"type":"realtime","audio":{"input":{"format":{"type":"audio/pcm","rate":16000}},"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#)
        let formats = try #require(RealtimeSession.audioFormats(of: conversation))
        #expect(formats.inputRate == 16_000)
        #expect(formats.outputRate == 24_000)

        let textOnly = RealtimeEvent(json: #"{"type":"session.created","session":{"type":"realtime","audio":{"input":{"format":{"type":"audio/pcm","rate":16000}}}}}"#)
        #expect(try #require(RealtimeSession.audioFormats(of: textOnly)).outputRate == nil)

        let transcription = RealtimeEvent(json: #"{"type":"session.updated","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":16000},"transcription":{}}}}}"#)
        #expect(try #require(RealtimeSession.audioFormats(of: transcription)).outputRate == nil)

        #expect(RealtimeSession.audioFormats(of: RealtimeEvent(json: #"{"type":"session.created","session":{}}"#)) == nil)
    }

    @Test func toleratesInvalidJSON() {
        let e = RealtimeEvent(json: "{not json")
        #expect(e.type == "")
        #expect(e.json == "{not json")
    }
}

struct RealtimeAudioResamplerTests {
    @Test func passesTargetRateThrough() throws {
        let r = try RealtimeAudioResampler(targetRate: 16_000)
        let samples = (0..<1600).map { Float($0) / 1600 }
        #expect(try r.convert(samples, sampleRate: 16_000) == samples)
        #expect(try r.convert([], sampleRate: 48_000).isEmpty)
    }

    @Test func resamplesChunksLikeOneBuffer() throws {
        let r = try RealtimeAudioResampler(targetRate: 16_000)
        // one second of a 440 Hz tone at 48 kHz, in 100 ms chunks
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        var out: [Float] = []
        for start in stride(from: 0, to: tone.count, by: 4_800) {
            out += try r.convert(Array(tone[start..<start + 4_800]), sampleRate: 48_000)
        }
        out += try r.flush()
        #expect(abs(out.count - 16_000) <= 32)
        let peak = out.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6)
    }

    @Test func mixesDownStereoBuffers() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        for c in 0..<2 {
            let channel = try #require(buffer.floatChannelData?[c])
            for i in 0..<4_410 { channel[i] = 0.3 }
        }
        let r = try RealtimeAudioResampler(targetRate: 16_000)
        var out = try r.convert(buffer)
        out += try r.flush()
        #expect(abs(out.count - 1_600) <= 32)
        #expect(out.dropFirst(100).allSatisfy { $0 > 0.1 })
    }
}

/// Opt-in: set LLAMA_ENGINE_TEST_REALTIME_MODEL, LLAMA_ENGINE_TEST_REALTIME_MMPROJ
/// (LFM3-Omni-2B) and LLAMA_ENGINE_TEST_REALTIME_PCM (16 kHz PCM16 speech).
/// Serialized: concurrent model loads in one process crash in llama_model_loader.
@Suite(.serialized)
struct RealtimeSessionModelTests {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["LLAMA_ENGINE_TEST_REALTIME_MODEL"] != nil }

    static func loadedEngine() async throws -> LlamaEngine {
        let engine = LlamaEngine()
        try await engine.load(ModelConfig(
            modelPath: URL(fileURLWithPath: env["LLAMA_ENGINE_TEST_REALTIME_MODEL"]!),
            contextSize: 4096,
            gpuLayers: -1,
            mtmdProjectorPath: env["LLAMA_ENGINE_TEST_REALTIME_MMPROJ"].map { URL(fileURLWithPath: $0) }
        ))
        return engine
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func answersASpokenQuestionAt48kHz() async throws {
        let engine = try await Self.loadedEngine()
        #expect(try await engine.capabilities().engineOperations?.realtime == true)

        let pcm = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.env["LLAMA_ENGINE_TEST_REALTIME_PCM"])))
        // the app audio comes at the hardware rate: go through 48 kHz to exercise the resampler
        let up = try RealtimeAudioResampler(targetRate: 48_000)
        let samples48k = try up.convert(RealtimePCM16.decode(pcm), sampleRate: 16_000) + up.flush()

        let session = try await engine.openRealtimeSession()
        var iterator = session.makeAsyncIterator()
        let created = try await iterator.next()
        #expect(created?.type == "session.created")
        #expect(session.inputSampleRate == 16_000)

        do {
            _ = try await engine.chatCompletion(requestJSON: #"{"messages":[{"role":"user","content":"hi"}]}"#)
            Issue.record("chat must be refused while a session is open")
        } catch LlamaError.busy {
        }

        try session.updateSession(instructions: "Answer in one short sentence.", outputModalities: [.text])
        for start in stride(from: 0, to: samples48k.count, by: 4_800) {
            try session.appendAudio(Array(samples48k[start..<min(start + 4_800, samples48k.count)]), sampleRate: 48_000)
        }
        try session.commitAudio()
        try session.createResponse()

        var answer = ""
        while let event = try await iterator.next() {
            #expect(event.error == nil)
            if event.type == "response.output_text.delta" { answer += event.textDelta ?? "" }
            if event.type == "response.done" { break }
        }
        #expect(answer.localizedCaseInsensitiveContains("paris"))

        session.close()
        while try await iterator.next() != nil {}
        #expect(throws: LlamaError.self) { try session.cancelResponse() }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func speaksTheAnswerOfASpokenQuestion() async throws {
        let engine = try await Self.loadedEngine()
        let pcm = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.env["LLAMA_ENGINE_TEST_REALTIME_PCM"])))

        let session = try await engine.openRealtimeSession()
        #expect(session.supportsAudioOutput)
        #expect(session.outputSampleRate == 24_000)

        try session.updateSession(instructions: "Answer in one short sentence.")
        try session.appendAudio(RealtimePCM16.decode(pcm), sampleRate: 16_000)
        try session.commitAudio()
        try session.createResponse(outputModalities: [.text, .audio])

        var answer = ""
        var samples = 0
        for try await event in session {
            #expect(event.error == nil)
            answer += event.type == "response.output_text.delta" ? event.textDelta ?? "" : ""
            if let audio = event.audio {
                #expect(!audio.isEmpty)
                samples += audio.count
            }
            if event.type == "response.done" {
                #expect((event.object?["response"] as? [String: Any])?["status"] as? String == "completed")
                break
            }
        }
        #expect(answer.localizedCaseInsensitiveContains("paris"))
        // at least half a second of voice; the quality is checked by ear
        #expect(Double(samples) >= session.outputSampleRate / 2)
        session.close()
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func callsAToolThenSpeaksTheAnswer() async throws {
        let engine = try await Self.loadedEngine()
        let session = try await engine.openRealtimeSession()
        let weather = RealtimeTool(name: "get_weather", description: "Get the current weather for a city.",
                                   parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)
        // the system prompt of the LFM3-Omni model card for tools
        try session.updateSession(instructions: "Respond with function calls, and interleaved text and audio.",
                                  outputModalities: [.text, .audio], tools: [weather])
        try session.addUserText("What is the weather in Paris right now?")
        try session.createResponse()

        var iterator = session.makeAsyncIterator()
        var call: RealtimeFunctionCall?
        var callSamples = 0
        while let event = try await iterator.next() {
            #expect(event.error == nil)
            call = event.functionCall ?? call
            callSamples += event.audio?.count ?? 0
            if event.type == "response.done" { break }
        }
        let made = try #require(call)
        #expect(made.name == "get_weather")
        #expect(made.arguments.contains("Paris"))
        #expect(callSamples == 0)

        try session.sendFunctionCallOutput(callID: made.callID, output: #"{"temperature_c": 14, "condition": "light rain"}"#)
        try session.createResponse()
        var answer = ""
        var samples = 0
        while let event = try await iterator.next() {
            #expect(event.error == nil)
            #expect(event.functionCall == nil)
            answer += event.type == "response.output_text.delta" ? event.textDelta ?? "" : ""
            samples += event.audio?.count ?? 0
            if event.type == "response.done" { break }
        }
        #expect(answer.contains("14") || answer.localizedCaseInsensitiveContains("fourteen"))
        #expect(Double(samples) >= session.outputSampleRate / 2)
        session.close()
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func transcriptionSessionHasNoAudioOutput() async throws {
        let engine = try await Self.loadedEngine()
        // without an "asr" chat template, LFM3-Omni opens a conversation: switch it
        let session = try await engine.openRealtimeSession()
        #expect(session.supportsAudioOutput)
        try session.send(json: #"{"type": "session.update", "session": {"type": "transcription"}}"#)
        for try await event in session where event.type == "session.updated" {
            break
        }
        #expect(!session.supportsAudioOutput)
        session.close()
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func pauseEndsTheSessionWithSessionTerminated() async throws {
        let engine = try await Self.loadedEngine()
        let session = try await engine.openRealtimeSession()
        try session.addUserText("Write a long story about a lighthouse.")
        try session.createResponse()

        var last: RealtimeEvent?
        var paused = false
        for try await event in session {
            last = event
            // the long response must not finish: the pause stops it
            #expect(event.type != "response.done")
            if event.type == "response.output_text.delta" && !paused {
                paused = true
                try await engine.pause()
            }
        }
        #expect(last?.error?.code == "session_terminated")
        #expect(last?.error?.isTerminal == true)
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func cancellingTheReaderClosesTheSession() async throws {
        let engine = try await Self.loadedEngine()
        let session = try await engine.openRealtimeSession()
        let reader = Task {
            var n = 0
            for try await _ in session { n += 1 }
            return n
        }
        try session.addUserText("Write a long story.")
        try session.createResponse()
        reader.cancel()
        _ = try? await reader.value
        #expect(throws: LlamaError.self) { try session.cancelResponse() }

        // the slot comes back: a new session opens
        let next = try await engine.openRealtimeSession()
        next.close()
    }
}
