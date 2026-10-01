import CoreGraphics
import CoreImage
import Foundation
import FoundationModels
import ImageIO
@testable import LlamaFMDemo
import LlamaEngine
import LlamaFoundationModels
import os
import Testing

// P7: the capabilities the catalog announces, measured on a device with the
// model the app downloaded (the hosted tests share the app's container). The
// model is registered in a runtime of the test, with the capabilities of its
// catalog entry. Opt-in, slow:
//
//   TEST_RUNNER_LLAMA_DEVICE_QUALIFICATION=1
//   TEST_RUNNER_LLAMA_QUALIFICATION_OFFLOAD=none|all   (default: all, Metal)
//
// The app must be signed for the device: pass DEVELOPMENT_TEAM=<team> (and
// -allowProvisioningUpdates) to xcodebuild.
//
// Answers are checked on facts a correct answer must contain, not on wording.
// Lines starting with "P7" are the measures of the report.

private let environment = ProcessInfo.processInfo.environment
private let qwen = LlamaModelID("qwen3.5-2b-q4_k_m")
private let artifact: LlamaModelArtifact? = environment["LLAMA_DEVICE_QUALIFICATION"] == "1"
    ? (try? LlamaModelStore.applicationSupport().artifacts())?.first { $0.id == qwen }
    : nil
private let offload: LlamaComputeConfiguration.Offload = environment["LLAMA_QUALIFICATION_OFFLOAD"] == "none" ? .none : .all
private let profile = LlamaLoadProfile(contextSize: 4096, compute: LlamaComputeConfiguration(offload: offload),
                                       usesProjector: true)
private let noReasoning = ContextOptions(reasoningLevel: .custom("none"))

private final class BundleToken {}
private let newspaper = Bundle(for: BundleToken.self).url(forResource: "newspaper", withExtension: "jpeg")!

/// One runtime for the suite, with the demo's limits: one resident model, one generation.
private let shared: LlamaRuntime? = {
    guard let artifact else { return nil }
    let runtime = try! LlamaRuntime(configuration: LlamaRuntime.Configuration(
        limits: LlamaRuntime.Limits(maximumResidentModels: 1, maximumActiveGenerations: 1, maximumWaitingRequests: 4)))
    try! runtime.register(artifact)
    return runtime
}()

private func model(_ monitor: LlamaGenerationMonitor? = nil, profile: LlamaLoadProfile = profile) -> LlamaLanguageModel {
    LlamaLanguageModel(runtime: shared!, modelID: qwen, profile: profile, monitor: monitor)
}

@Generable struct Headline {
    @Guide(description: "The main headline, as printed") var headline: String
    @Guide(description: "The number of photographs on the page", .range(0...20)) var photographs: Int
}

@Generable struct Amount {
    @Guide(description: "The total in EUR") var total: Double
}

// MARK: Measures

/// Physical footprint of the process (what iOS counts against its limit), its
/// lifetime peak, and the memory still available to it (iOS only; -1 on macOS).
struct MemorySample: CustomStringConvertible {
    var footprint: Int64
    var peak: Int64
    var available: Int64

    static func now() -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemorySample(footprint: -1, peak: -1, available: -1) }
        #if os(iOS)
        let available = Int64(os_proc_available_memory())
        #else
        let available: Int64 = -1
        #endif
        return MemorySample(footprint: Int64(info.phys_footprint), peak: Int64(info.ledger_phys_footprint_peak),
                            available: available)
    }

    private static func mb(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    var description: String { "footprint \(Self.mb(footprint)), peak \(Self.mb(peak)), available \(Self.mb(available))" }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Timestamps of a request's phases, read from its monitor.
private final class PhaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var firstGenerating: Double?
    private var task: Task<Void, Never>?

    init(_ monitor: LlamaGenerationMonitor, start: ContinuousClock.Instant) {
        task = Task { [weak self] in
            for await state in monitor.updates() where state.phase == .generating {
                self?.lock.withLock { if self?.firstGenerating == nil { self?.firstGenerating = seconds(since: start) } }
            }
        }
    }

    /// Seconds from the start to the first generated token.
    var firstToken: Double? { lock.withLock { firstGenerating } }

    deinit { task?.cancel() }
}

private func joinedText(_ segments: [Transcript.Segment]) -> String {
    segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
}

private func toolOutputs(_ transcript: Transcript) -> [String] {
    transcript.compactMap { entry -> String? in
        guard case .toolOutput(let o) = entry else { return nil }
        return "\(o.toolName):" + joinedText(o.segments)
    }
}

@Suite(.serialized, .enabled(if: artifact != nil, "set TEST_RUNNER_LLAMA_DEVICE_QUALIFICATION=1 with the catalog model installed"))
struct DeviceQualificationTests {
    /// The capabilities come from the qualified catalog entry, not from the test.
    @Test func capabilitiesFromTheCatalog() {
        let capabilities = model().capabilities
        print("P7 capabilities: \(capabilities)")
        #expect(capabilities.contains(.guidedGeneration))
        #expect(capabilities.contains(.toolCalling))
        #expect(capabilities.contains(.reasoning))
        #expect(capabilities.contains(.vision))
    }

    /// Memory, load, first token, prompt and generation rates, image encoding,
    /// cancellation delay and unload, in that order on a fresh instance.
    @Test func measures() async throws {
        let runtime = shared!
        try await runtime.unload(qwen)
        let idle = MemorySample.now()
        print("P7 memory idle: \(idle)")

        var start = ContinuousClock.now
        try await runtime.load(qwen, profile: profile)
        let load = seconds(since: start)
        let loaded = MemorySample.now()
        print("P7 load: \(String(format: "%.2f", load)) s (offload \(offload)), memory \(loaded)")

        // First token of a short request on a loaded model.
        do {
            let monitor = LlamaGenerationMonitor()
            let session = LanguageModelSession(model: model(monitor))
            start = ContinuousClock.now
            let clock = PhaseClock(monitor, start: start)
            let response = try await session.respond(to: "What is the capital of France? Answer with one word.",
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16),
                                                     contextOptions: noReasoning)
            print("P7 first token: \(String(format: "%.3f", clock.firstToken ?? -1)) s, total \(String(format: "%.3f", seconds(since: start))) s, "
                + "prompt \(session.usage.input.totalTokenCount) tokens, answer '\(response.content)'")
            #expect(response.content.contains("Paris"))
        }

        // Generation rate: tokens after the first one over the time after it.
        do {
            let monitor = LlamaGenerationMonitor()
            let session = LanguageModelSession(model: model(monitor))
            start = ContinuousClock.now
            let clock = PhaseClock(monitor, start: start)
            _ = try await session.respond(to: "Write a story of about 300 words about a lighthouse keeper.",
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 256),
                                          contextOptions: noReasoning)
            let total = seconds(since: start)
            let generated = session.usage.output.totalTokenCount
            let first = clock.firstToken ?? 0
            let rate = Double(generated - 1) / max(total - first, 0.001)
            print("P7 generation: \(generated) tokens in \(String(format: "%.2f", total)) s, first token \(String(format: "%.3f", first)) s, "
                + "\(String(format: "%.1f", rate)) tokens/s, memory \(MemorySample.now())")
            #expect(generated > 100)
        }

        // Prompt rate: a long prompt, one token generated, no cached prefix.
        do {
            let monitor = LlamaGenerationMonitor()
            let session = LanguageModelSession(model: model(monitor))
            let filler = (1...150).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")
            start = ContinuousClock.now
            let clock = PhaseClock(monitor, start: start)
            _ = try await session.respond(to: filler + "\nHow many lines are there?",
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1),
                                          contextOptions: noReasoning)
            let prompt = (monitor.state.context?.promptTokens ?? 0) - (monitor.state.context?.cachedTokens ?? 0)
            let elapsed = clock.firstToken ?? seconds(since: start)
            print("P7 prompt: \(prompt) tokens processed in \(String(format: "%.2f", elapsed)) s, "
                + "\(String(format: "%.1f", Double(prompt) / max(elapsed, 0.001))) tokens/s")
            #expect(prompt > 1000)
        }

        // Image: encoding and its prompt, to the first token.
        do {
            let monitor = LlamaGenerationMonitor()
            let session = LanguageModelSession(model: model(monitor))
            start = ContinuousClock.now
            let clock = PhaseClock(monitor, start: start)
            let response = try await session.respond(
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32), contextOptions: noReasoning) {
                "What is the main headline of this newspaper?"
                Attachment(imageURL: newspaper)
            }
            print("P7 image: first token \(String(format: "%.2f", clock.firstToken ?? -1)) s, total \(String(format: "%.2f", seconds(since: start))) s, "
                + "prompt \(session.usage.input.totalTokenCount) tokens, '\(response.content)', memory \(MemorySample.now())")
            #expect(response.content.uppercased().contains("MOON"))
        }

        // Cancellation: until the task returns, and until the native request stopped (its admission released).
        var delays: [Double] = []
        var stops: [Double] = []
        for _ in 1...5 {
            let monitor = LlamaGenerationMonitor()
            let session = LanguageModelSession(model: model(monitor))
            let task = Task {
                try await session.respond(to: "Count from 1 to 2000, separated by commas.",
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 3000),
                                          contextOptions: noReasoning)
            }
            try await until(.seconds(60)) { (monitor.state.context?.generatedTokens ?? 0) > 20 }
            start = ContinuousClock.now
            task.cancel()
            let result = await task.result
            delays.append(seconds(since: start))
            guard case .failure(let error) = result else {
                Issue.record("not cancelled")
                continue
            }
            #expect(error is CancellationError)
            // the next request runs once the native slot is free again
            _ = try await LanguageModelSession(model: model()).respond(
                to: "Say OK.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 2),
                contextOptions: noReasoning)
            stops.append(seconds(since: start))
        }
        print("P7 cancellation: returned after \(delays.map { String(format: "%.3f", $0) }) s, "
            + "next 2-token request answered after \(stops.map { String(format: "%.3f", $0) }) s")
        #expect(delays.allSatisfy { $0 < 0.5 })
        #expect(stops.allSatisfy { $0 < 2 })

        let beforeUnload = MemorySample.now()
        start = ContinuousClock.now
        try await runtime.unload(qwen)
        let unload = seconds(since: start)
        try await Task.sleep(for: .seconds(1))
        let unloaded = MemorySample.now()
        print("P7 unload: \(String(format: "%.2f", unload)) s, before \(beforeUnload), after \(unloaded)")
        #expect(unloaded.footprint < beforeUnload.footprint)
    }

    /// Load and unload cycles, with and without the projector: the memory does
    /// not grow from one cycle to the next, and goes back near its idle level.
    /// On iOS 27.2 the freed memory stays in the footprint for about a minute
    /// before the system takes it back (observed without memory pressure).
    @Test func unloadReleasesTheMemory() async throws {
        let runtime = shared!
        try await runtime.unload(qwen)
        let idle = MemorySample.now()
        var unloaded: [Int64] = []
        for usesProjector in [false, true, false, true] {
            var cycle = profile
            cycle.usesProjector = usesProjector
            try await runtime.load(qwen, profile: cycle)
            let loaded = MemorySample.now()
            try await runtime.unload(qwen)
            var after: [Int64] = []
            for _ in 1...3 {
                try await Task.sleep(for: .seconds(1))
                after.append(MemorySample.now().footprint >> 20)
            }
            unloaded.append(after.last! << 20)
            print("P7 load/unload (projector \(usesProjector)): before \(idle.footprint >> 20) MB, "
                + "loaded \(loaded.footprint >> 20) MB, unloaded \(after.map { "\($0)" }.joined(separator: " / ")) MB after 1/2/3 s")
        }
        // no growth: the last cycle ends where the second one did
        #expect(unloaded[3] < unloaded[1] + 100 * 1_048_576)
        // back near the level of an unload without projector (the idle level of
        // the suite may include memory a previous test freed but not yet returned)
        let target = unloaded[0] + 200 * 1_048_576
        let start = ContinuousClock.now
        while MemorySample.now().footprint > target, seconds(since: start) < 180 {
            try await Task.sleep(for: .seconds(1))
        }
        print("P7 memory after the last unload: \(MemorySample.now().footprint >> 20) MB after \(Int(seconds(since: start))) s more")
        #expect(MemorySample.now().footprint < target)
    }

    @Test func text() async throws {
        let session = LanguageModelSession(model: model())
        var snapshots = 0
        var answer = ""
        for try await snapshot in session.streamResponse(
            to: "Name the three largest cities of Japan, separated by commas.",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 48), contextOptions: noReasoning) {
            snapshots += 1
            answer = snapshot.content
        }
        print("P7 text: \(snapshots) snapshots, '\(answer)'")
        #expect(snapshots > 2)
        #expect(answer.contains("Tokyo"))
    }

    @Test func reasoningIsSeparate() async throws {
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(to: "What is 17 + 25? Answer with the number only.",
                                                 options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1500))
        let reasoning = session.transcript.compactMap { entry -> String? in
            guard case .reasoning(let r) = entry else { return nil }
            return joinedText(r.segments)
        }
        print("P7 reasoning: \(reasoning.first?.count ?? 0) characters, \(session.usage.output.reasoningTokenCount) tokens, answer '\(response.content)'")
        #expect(!(reasoning.first ?? "").isEmpty)
        #expect(response.content.contains("42"))
        #expect(!response.content.contains("<think>"))
    }

    @Test func structuredOutputStreams() async throws {
        let session = LanguageModelSession(model: model())
        var partials = 0
        var last: CityGuide.PartiallyGenerated?
        for try await snapshot in session.streamResponse(
            to: "Lyon", generating: CityGuide.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))) {
            partials += 1
            last = snapshot.content
        }
        let guide = try #require(last)
        print("P7 structured: \(partials) snapshots, \(String(describing: guide))")
        #expect(partials > 3)
        #expect(guide.name?.contains("Lyon") == true)
        #expect(guide.country?.contains("France") == true)
        #expect(guide.landmarks?.count == 3)
    }

    @Test func reasoningWithStructuredOutput() async throws {
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(to: "A pen costs 3 EUR. What do 7 pens cost?", generating: Amount.self,
                                                 options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1500),
                                                 contextOptions: ContextOptions(includeSchemaInPrompt: false))
        let reasoned = session.transcript.contains { if case .reasoning = $0 { true } else { false } }
        print("P7 reasoning + structured: \(response.content.total), reasoning \(reasoned)")
        #expect(response.content.total == 21)
        #expect(reasoned)
    }

    @Test func toolLoop() async throws {
        let session = LanguageModelSession(model: model(), tools: [CalculatorTool(), ProductLookupTool()],
                                           instructions: "Use the tools to answer. Do not compute or guess yourself.")
        let response = try await session.respond(
            to: "How much are 3 pens and a mug in total?",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600), contextOptions: noReasoning)
        let outputs = toolOutputs(session.transcript)
        print("P7 tools: \(outputs) answer '\(response.content)'")
        #expect(outputs.contains { $0.hasPrefix("lookup_product:pen") })
        #expect(outputs.contains { $0.hasPrefix("lookup_product:mug") })
        #expect(response.content.contains("17"))
    }

    @Test func toolsWithStructuredOutput() async throws {
        let session = LanguageModelSession(model: model(), tools: [ProductLookupTool()])
        let response = try await session.respond(
            to: "Look up the price of a backpack, then give the price of two backpacks.", generating: Amount.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400, toolCallingMode: .required),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none")))
        print("P7 tools + structured: \(toolOutputs(session.transcript)) total \(response.content.total)")
        #expect(toolOutputs(session.transcript).contains { $0.hasPrefix("lookup_product:backpack") })
        #expect(response.content.total == 78)
    }

    @Test func visionWithStructuredOutput() async throws {
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(
            generating: Headline.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))) {
            "Read this newspaper page."
            Attachment(imageURL: newspaper)
        }
        print("P7 vision + structured: \(response.content)")
        #expect(response.content.headline.uppercased().contains("MOON"))
    }

    @Test func visionKeepsTheOrientation() async throws {
        let source = try #require(CGImageSourceCreateWithURL(newspaper as CFURL, nil))
        let upright = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // the page turned on its side, with the orientation that puts it back upright
        let sideways = CIImage(cgImage: upright).oriented(.left)
        let turned = try #require(CIContext().createCGImage(sideways, from: sideways.extent))
        let session = LanguageModelSession(model: model())
        let response = try await session.respond(
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32), contextOptions: noReasoning) {
            "What is the main headline of this newspaper?"
            Attachment(turned, orientation: .right)
        }
        print("P7 vision (orientation): '\(response.content)'")
        #expect(response.content.uppercased().contains("MOON"))
    }

    @Test func twoSessionsShareOneInstance() async throws {
        let a = LanguageModelSession(model: model())
        let b = LanguageModelSession(model: model())
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
        async let x = a.respond(to: "What is the capital of Italy? One word.", options: options, contextOptions: noReasoning)
        async let y = b.respond(to: "What is the capital of Spain? One word.", options: options, contextOptions: noReasoning)
        let (rx, ry) = try await (x, y)
        #expect(rx.content.contains("Rome"))
        #expect(ry.content.contains("Madrid"))
        #expect(shared!.snapshot()[qwen]?.instances.filter { $0.profile == profile }.count == 1)
    }

    @Test func interruptionThenNextRequest() async throws {
        let monitor = LlamaGenerationMonitor()
        let session = LanguageModelSession(model: model(monitor))
        let task = Task {
            try await session.respond(to: "Count from 1 to 2000, separated by commas.",
                                      options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 3000),
                                      contextOptions: noReasoning)
        }
        try await until(.seconds(60)) { (monitor.state.context?.generatedTokens ?? 0) > 20 }
        task.cancel()
        _ = await task.result
        let next = try await session.respond(to: "What is the capital of Germany? One word.",
                                             options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16),
                                             contextOptions: noReasoning)
        print("P7 after interruption: '\(next.content)'")
        #expect(next.content.contains("Berlin"))
    }

    @Test func contextFullBeforeAndDuringGeneration() async throws {
        try await shared!.unload(qwen)                   // one resident instance: make room for the small profile
        let small = LlamaLoadProfile(contextSize: 256, compute: LlamaComputeConfiguration(offload: offload))
        let session = LanguageModelSession(model: model(profile: small))
        do {
            _ = try await session.respond(to: String(repeating: "This sentence fills the context. ", count: 60),
                                          contextOptions: noReasoning)
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 256)
            #expect(info.debugDescription.contains("prompt"))
        }
        do {
            _ = try await session.respond(to: "Count from 1 to 500, separated by commas.",
                                          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 2000),
                                          contextOptions: noReasoning)
            Issue.record("expected an error")
        } catch let LanguageModelError.contextSizeExceeded(info) {
            #expect(info.contextSize == 256)
            #expect(info.debugDescription.contains("generation"))
        }
        let short = try await session.respond(to: "Count from 1 to 500, separated by commas.",
                                              options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 10),
                                              contextOptions: noReasoning)
        #expect(!short.content.isEmpty)
        try await shared!.unload(qwen)
    }
}
