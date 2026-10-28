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

    @Test func reasoningEffortIncludesMax() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        #expect(LlamaOpenAICompatibleReasoningEffort(rawValue: "max") == .max)
    }

    @Test func automaticMappingKeepsExactStandardLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: ["low", "high", "max", "ultra"],
            supportsReasoningToggle: true
        )

        #expect(mapping.supportedReasoningLevels == [.light, .deep, .custom("max")])
        #expect(mapping.value(for: .light) == "low")
        #expect(mapping.value(for: .deep) == "high")
        #expect(mapping.value(for: .custom("max")) == "max")
    }

    @Test func automaticMappingDoesNotInventLevels() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let mapping = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: ["high"],
            supportsReasoningToggle: nil
        )

        #expect(mapping.supportedReasoningLevels == [.deep])
        #expect(mapping.unsupportedLevelDescription(for: .light) != nil)
        #expect(mapping.unsupportedLevelDescription(for: .deep) == nil)
        #expect(mapping.unsupportedLevelDescription(for: nil) == nil)
    }

    @Test func automaticMappingKeepsHistoricalBehaviourWhenUnknown() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let unknown = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: nil,
            supportsReasoningToggle: nil
        )
        let empty = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: [],
            supportsReasoningToggle: true
        )

        #expect(unknown == .openAICompatible)
        #expect(empty == .openAICompatible)
        #expect(LlamaOpenAICompatibleReasoningEffortMapping.openAICompatible.unsupportedLevelDescription(for: .custom("x")) == nil)
    }

    @Test func automaticMappingDoesNotForceThinkingOffWithoutToggle() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        let noToggle = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: ["low", "medium", "high"],
            supportsReasoningToggle: nil
        )
        #expect(noToggle.applying(nil, to: [:])["chat_template_kwargs"] == nil)

        let withToggle = LlamaOpenAICompatibleReasoningEffortMapping.automatic(
            reasoningEffortLevels: ["low", "medium", "high"],
            supportsReasoningToggle: true
        )
        guard case .object(let off) = withToggle.applying(nil, to: [:])["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs was not an object")
            return
        }
        #expect(off["enable_thinking"] == .bool(false))
        #expect(off["reasoning_effort"] == nil)

        guard case .object(let on) = noToggle.applying(.moderate, to: [:])["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs was not an object")
            return
        }
        #expect(on["enable_thinking"] == .bool(true))
        #expect(on["reasoning_effort"] == .string("medium"))
    }
}
