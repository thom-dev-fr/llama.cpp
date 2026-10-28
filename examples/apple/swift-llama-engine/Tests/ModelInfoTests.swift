import Foundation
import Testing
@testable import LlamaEngine

struct ModelInfoTests {
    @Test func decodesMissingModelInfoFieldsDefensively() throws {
        let data = Data("{}".utf8)

        let info = try JSONDecoder().decode(ModelInfo.self, from: data)

        #expect(info.architecture == "")
        #expect(info.metadata.fileSize == 0)
        #expect(!info.capabilities.hasAnyCapability)
        #expect(info.capabilities.supportsReasoningToggle == nil)
        #expect(info.projector == nil)
    }

    @Test func preservesKnownReasoningToggleSupport() throws {
        let capabilities = ModelCapabilities(
            supportsReasoning: true,
            supportsReasoningToggle: false
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)

        #expect(decoded.supportsReasoning)
        #expect(decoded.supportsReasoningToggle == false)
    }

    @Test func estimatesMemoryFromCompleteMetadata() {
        let info = ModelInfo(
            capabilities: ModelCapabilities(),
            metadata: GGUFFileInfo(
                blockCount: 2,
                embeddingLength: 128,
                contextLength: 1024,
                attentionHeadCount: 4,
                attentionHeadCountKV: 2,
                attentionKeyLength: 32,
                attentionValueLength: 32,
                fileSize: 1_000
            )
        )

        let estimate = info.estimatedMemoryUsage(
            parameters: MemoryEstimateParameters(
                contextSize: 1000,
                kvCacheType: .f16,
                includeProjector: false
            )
        )

        #expect(estimate.modelBytes == 1_000)
        #expect(estimate.projectorBytes == 0)
        #expect(estimate.effectiveContextSize == 1024)
        #expect(estimate.kvCacheBytes == 524_288)
        #expect(estimate.confidence == .high)
    }

    @Test func estimatesMissingMetadataWithLowConfidence() {
        let info = ModelInfo(metadata: GGUFFileInfo(fileSize: 42))

        let estimate = info.estimatedMemoryUsage(
            parameters: MemoryEstimateParameters(contextSize: 0, kvCacheType: .f16)
        )

        #expect(estimate.modelBytes == 42)
        #expect(estimate.kvCacheBytes == 0)
        #expect(estimate.effectiveContextSize == 4096)
        #expect(estimate.confidence == .low)
        #expect(estimate.warnings.contains { $0.contains("context_length is missing") })
        #expect(estimate.warnings.contains { $0.contains("block_count is missing") })
    }

    @Test func decodesEngineCapabilitiesDocument() throws {
        let json = #"""
        {
          "schema_version": 1,
          "future_section": {"x": 1},
          "chat_template": {
            "source": "override",
            "supports_tool_calls": true,
            "supports_reasoning": true,
            "supports_reasoning_toggle": null,
            "reasoning_effort_levels": ["low", "high", "ultra"],
            "future_flag": true
          }
        }
        """#

        let caps = try EngineCapabilities(json: json)

        #expect(caps.schemaVersion == 1)
        #expect(caps.chatTemplate?.source == "override")
        #expect(caps.chatTemplate?.supportsToolCalls == true)
        #expect(caps.chatTemplate?.supportsReasoningToggle == nil)
        #expect(caps.chatTemplate?.supportsSystemRole == nil)
        #expect(caps.chatTemplate?.reasoningEffortLevels == ["low", "high", "ultra"])
        #expect(caps.rawJSON.contains("future_section"))
    }

    @Test func distinguishesUnknownAndEmptyEffortLevels() throws {
        let unknown = try EngineCapabilities(json: #"{"schema_version":1,"chat_template":{"reasoning_effort_levels":null}}"#)
        let empty = try EngineCapabilities(json: #"{"schema_version":1,"chat_template":{"reasoning_effort_levels":[]}}"#)
        let failed = try EngineCapabilities(json: #"{"schema_version":1,"chat_template":null,"chat_template_error":"bad"}"#)

        #expect(unknown.chatTemplate?.reasoningEffortLevels == nil)
        #expect(empty.chatTemplate?.reasoningEffortLevels == [])
        #expect(failed.chatTemplate == nil)
        #expect(failed.chatTemplateError == "bad")
    }

    @Test func modelCapabilitiesKeepEffortLevelsOptional() throws {
        let old = try JSONDecoder().decode(ModelCapabilities.self, from: Data(#"{"supportsReasoning":true}"#.utf8))
        #expect(old.reasoningEffortLevels == nil)

        let caps = ModelCapabilities(supportsReasoning: true, reasoningEffortLevels: ["max"])
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: JSONEncoder().encode(caps))
        #expect(decoded.reasoningEffortLevels == ["max"])
    }

    @Test func decodesNativeMemoryReport() throws {
        let json = #"""
        {
          "schema_version": 1, "source": "native",
          "effective": {"n_ctx": 4096, "n_ctx_train": 32768, "type_k": "f16", "gpu_layers": -1, "future": 1},
          "rows": [
            {"kind": "device", "name": "MTL0", "model_bytes": 6442450944, "context_bytes": 1073741824,
             "compute_bytes": 1, "device_total_bytes": 34359738368, "device_free_bytes": 0},
            {"kind": "something_new", "name": "X", "model_bytes": 1, "context_bytes": 0, "compute_bytes": 0}
          ],
          "required_bytes": {"model": 6442450945, "context": 1073741824, "compute": 1, "total": 7516192770},
          "coverage": {"model": true, "context": true, "projector": false, "mtp_draft": true},
          "complete": false,
          "warnings": ["the multimodal projector is not measured"]
        }
        """#

        let report = try NativeMemoryReport(json: json)

        #expect(report.effective.contextSize == 4096)
        #expect(report.effective.batchSize == nil)
        #expect(report.rows[0].kind == .device)
        #expect(report.rows[0].totalBytes == 7_516_192_769)
        #expect(report.rows[0].deviceTotalBytes == 34_359_738_368)
        #expect(report.rows[1].kind == .unknown)
        #expect(report.requiredBytes.total == 7_516_192_770)
        #expect(!report.isComplete)
        #expect(!report.coverage.projector)
    }

    @Test func memoryUsageFallsBackOnlyWhenAsked() async throws {
        let config = ModelConfig(modelPath: URL(fileURLWithPath: "/nonexistent/model.gguf"))

        await #expect(throws: LlamaError.self) {
            _ = try await LlamaEngine.memoryUsage(for: config)
        }

        let usage = try await LlamaEngine.memoryUsage(
            for: config,
            fallback: .estimate(ModelInfo(metadata: GGUFFileInfo(fileSize: 42)))
        )
        guard case .estimated(let estimate, let nativeError) = usage else {
            Issue.record("expected an estimate")
            return
        }
        #expect(estimate.modelBytes == 42)
        #expect(!nativeError.isEmpty)
    }
}
