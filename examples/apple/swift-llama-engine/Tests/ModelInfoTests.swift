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
        #expect(info.projector == nil)
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
}
