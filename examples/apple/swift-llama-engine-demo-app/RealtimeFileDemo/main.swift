// Sends an audio file to a realtime session as a microphone would, in 100 ms
// chunks at the file's own rate, and prints the text of the response or the
// transcript. With --speak, the response is also spoken and the voice is
// written to a 24 kHz WAV file.
//
// swift run LlamaRealtimeFileDemo <model.gguf> <mmproj.gguf> <audio file> [--transcribe] [--speak OUT.wav] [--instructions TEXT]

import AVFoundation
import Foundation
import LlamaEngine

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
let transcribe = args.contains("--transcribe")
args.removeAll { $0 == "--transcribe" }
var speakURL: URL?
if let i = args.firstIndex(of: "--speak"), i + 1 < args.count {
    speakURL = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
var instructions = "Answer in one short sentence."
if let i = args.firstIndex(of: "--instructions"), i + 1 < args.count {
    instructions = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard args.count == 3, !(transcribe && speakURL != nil) else {
    fail("usage: LlamaRealtimeFileDemo <model.gguf> <mmproj.gguf> <audio file> [--transcribe] [--speak OUT.wav] [--instructions TEXT]")
}

LlamaEngine.setLogLevel(.error)
let engine = LlamaEngine()
try await engine.load(ModelConfig(
    modelPath: URL(fileURLWithPath: args[0]),
    contextSize: 4096,
    gpuLayers: -1,
    mtmdProjectorPath: URL(fileURLWithPath: args[1])
))
guard try await engine.capabilities().engineOperations?.realtime == true else {
    fail("this model cannot run a realtime session")
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
print("audio: \(file.length) frames at \(file.processingFormat.sampleRate) Hz, \(file.processingFormat.channelCount) channel(s)")

let session = try await engine.openRealtimeSession()
if transcribe {
    try session.send(json: #"{"type": "session.update", "session": {"type": "transcription"}}"#)
} else {
    try session.updateSession(instructions: instructions, outputModalities: [.text])
}
if speakURL != nil && !session.supportsAudioOutput {
    fail("this model cannot answer with audio")
}

let started = Date()
while file.framePosition < file.length {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
        fail("cannot allocate an audio buffer")
    }
    try file.read(into: buffer, frameCount: chunkFrames)
    try session.appendAudio(buffer)
}
try session.commitAudio()
let responseStart = Date()
if !transcribe {
    try session.createResponse(outputModalities: speakURL != nil ? [.text, .audio] : [.text])
}

let endType = transcribe ? "conversation.item.input_audio_transcription.completed" : "response.done"
var first: TimeInterval?
var firstAudio: TimeInterval?
var voice: [Float] = []
for try await event in session {
    if let audio = event.audio {
        firstAudio = firstAudio ?? Date().timeIntervalSince(started)
        voice += audio
    }
    if let text = event.textDelta {
        first = first ?? Date().timeIntervalSince(started)
        print(text, terminator: "")
        fflush(stdout)
    }
    if let error = event.error {
        print("\nerror: \(error.message)")
        if error.isTerminal { break }
    }
    if event.type == endType {
        break
    }
}
print("")
let done = Date()
if let first {
    print(String(format: "first text after %.2f s, done after %.2f s", first, done.timeIntervalSince(started)))
}
if let speakURL {
    guard !voice.isEmpty else { fail("the response has no voice") }
    let rate = session.outputSampleRate
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(voice.count)) else {
        fail("cannot allocate the voice buffer")
    }
    buffer.frameLength = AVAudioFrameCount(voice.count)
    voice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: voice.count) }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let out = try AVAudioFile(forWriting: speakURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try out.write(from: buffer)
    let seconds = Double(voice.count) / rate
    // generated faster than real time above 1x, measured from response.create
    print(String(format: "voice: %.2f s at %.0f Hz, first audio after %.2f s, generated at %.2fx real time -> %@",
                 seconds, rate, firstAudio ?? 0, seconds / done.timeIntervalSince(responseStart), speakURL.path))
}
session.close()
try await engine.unload()
