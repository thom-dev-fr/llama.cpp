import Testing
@testable import LlamaEngine

struct GGUFFilenameTests {
    @Test func parsesQuantizedModelFilename() {
        let info = GGUFFilename.parse("Qwen2.5-Omni-3B-Q4_K_M.gguf")

        #expect(info.displayName == "Qwen2.5 Omni 3B")
        #expect(info.quantizationSuffix == "Q4_K_M")
        #expect(info.baseName == "Qwen2.5-Omni-3B")
    }

    @Test func keepsUnknownExtensionInDisplayName() {
        let info = GGUFFilename.parse("local-model.custom")

        #expect(info.displayName == "Local model.custom")
        #expect(info.quantizationSuffix == nil)
        #expect(info.baseName == "local")
    }

    @Test func returnsNilBaseNameForSinglePartFilename() {
        #expect(GGUFFilename.baseName(from: "model.gguf") == nil)
    }
}
