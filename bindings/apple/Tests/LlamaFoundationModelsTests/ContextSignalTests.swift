import Foundation
import FoundationModels
import LlamaEngine
@testable import LlamaFoundationModels
import Testing

// P1: the engine's context signals (fail_on_context_full, return_context) as
// the Swift side reads them. The JSON samples follow the native payloads
// produced by tests/test-engine-context.cpp.

@Suite struct ContextSignalTests {
    @Test func generationOverflowBecomesContextSizeExceeded() throws {
        let data = Data("""
        {"code":400,"message":"the context is full after 99 generated tokens (prompt: 29 tokens, context size: 128 tokens)",
         "type":"exceed_context_size_error","n_prompt_tokens":29,"n_ctx":128,"context_phase":"generation","n_decoded":99}
        """.utf8)
        let overflow = try #require(LlamaContextOverflow(errorData: data))
        #expect(overflow.phase == .generation)
        #expect(overflow.requiredTokens == 129)

        guard case let .contextSizeExceeded(info) = LanguageModelError.contextSizeExceeded(overflow) else {
            Issue.record("unexpected error case")
            return
        }
        #expect(info.contextSize == 128)
        #expect(info.tokenCount == 129)
        #expect(info.debugDescription.hasPrefix("context full during generation:"))
        #expect(info.debugDescription.contains("99 generated tokens"))
    }

    @Test func promptOverflowKeepsThePromptSize() throws {
        let data = Data("""
        {"code":400,"message":"request (600 tokens) exceeds the available context size (128 tokens), try increasing it",
         "type":"exceed_context_size_error","n_prompt_tokens":600,"n_ctx":128,"context_phase":"prompt","n_decoded":0}
        """.utf8)
        let overflow = try #require(LlamaContextOverflow(errorData: data))
        #expect(overflow.phase == .prompt)
        #expect(overflow.requiredTokens == 600)
    }

    @Test func otherErrorsAreNotContextOverflows() {
        // without the phase (request not made by this library) or another type
        #expect(LlamaContextOverflow(errorData: Data("""
            {"type":"exceed_context_size_error","n_prompt_tokens":600,"n_ctx":128}
            """.utf8)) == nil)
        #expect(LlamaContextOverflow(errorData: Data("""
            {"type":"server_error","message":"x","n_prompt_tokens":1,"n_ctx":1,"context_phase":"prompt"}
            """.utf8)) == nil)
    }

    @Test func contextReportDecodes() throws {
        let data = Data("""
        {"n_ctx":128,"n_tokens":46,"n_prompt_tokens":34,"n_cache_tokens":0,"n_decoded":12,"n_reasoning_tokens":12}
        """.utf8)
        let report = try JSONDecoder().decode(LlamaContextReport.self, from: data)
        #expect(report.contextSize == 128 && report.occupiedTokens == 46)
        #expect(report.generatedTokens == 12 && report.reasoningTokens == 12)
        #expect(abs(report.occupancy - 46.0 / 128.0) < 1e-9)
    }
}
