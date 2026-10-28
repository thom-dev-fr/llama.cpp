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
}
