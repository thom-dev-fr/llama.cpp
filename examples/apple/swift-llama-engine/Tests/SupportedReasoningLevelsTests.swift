import Foundation
import FoundationModels
import Testing
@testable import LlamaEngine
@testable import LlamaLanguageModel
@testable import LlamaOpenAICompatible
@testable import LlamaServerLanguageModel

struct SupportedReasoningLevelsTests {
    @Test func reasoningEffortMappingExposesEnabledBuiltInLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .light: .minimal,
            .moderate: .none,
            .deep: .xhigh,
        ])

        #expect(mapping.supportedReasoningLevels == [.light, .deep])
    }

    @Test func reasoningEffortMappingExposesConfiguredCustomLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .deep: .high,
            .custom("xhigh"): .xhigh,
        ])

        #expect(mapping.supportedReasoningLevels == [.deep, .custom("xhigh")])
    }

    @Test func localModelDerivesSupportedReasoningLevelsFromMapping() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .moderate: .low,
            .deep: .xhigh,
        ])
        let model = LlamaLanguageModel(
            name: "test",
            configuration: ModelConfig(modelPath: URL(fileURLWithPath: "/tmp/model.gguf")),
            reasoningEffortMapping: mapping,
            capabilities: [.reasoning]
        )

        #expect(model.supportedReasoningLevels == mapping.supportedReasoningLevels)
    }

    @Test func serverModelDerivesSupportedReasoningLevelsFromMapping() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .deep: .high,
            .custom("xhigh"): .xhigh,
        ])
        let model = LlamaServerLanguageModel(
            name: "test",
            url: try #require(URL(string: "http://localhost:8080")),
            reasoningEffortMapping: mapping,
            capabilities: [.reasoning]
        )

        #expect(model.supportedReasoningLevels == mapping.supportedReasoningLevels)
    }

    @Test func reasoningEffortMappingAppliesConfiguredBuiltInAndCustomLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .moderate: .low,
            .deep: .xhigh,
            .custom("xhigh"): .xhigh,
        ])

        #expect(mapping.value(for: .light) == "none")
        #expect(mapping.value(for: .moderate) == "low")
        #expect(mapping.value(for: .deep) == "xhigh")
        #expect(mapping.value(for: .custom("xhigh")) == "xhigh")
        #expect(mapping.value(for: .custom("provider-specific")) == "none")
    }

    @Test func reasoningEffortMappingUpdatesChatTemplateKwargs() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping.openAICompatible
        let body = mapping.applying(.deep, to: [
            "chat_template_kwargs": .object([
                "existing": .bool(true),
            ]),
        ])

        guard case .object(let kwargs) = body["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs was not an object")
            return
        }

        #expect(kwargs["existing"] == .bool(true))
        #expect(kwargs["reasoning_effort"] == .string("high"))
        #expect(kwargs["enable_thinking"] == .bool(true))
    }

    @Test func reasoningEffortMappingDisablesUnmappedLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping([
            .deep: .xhigh,
        ])
        let body = mapping.applying(.custom("xhigh"), to: [:])

        guard case .object(let kwargs) = body["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs was not an object")
            return
        }

        #expect(kwargs["reasoning_effort"] == .string("none"))
        #expect(kwargs["enable_thinking"] == .bool(false))
    }
}
