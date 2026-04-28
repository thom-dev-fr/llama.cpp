import Foundation

public enum EngineState: Int, Sendable, CustomStringConvertible {
    case unloaded  = 0
    case loading   = 1
    case ready     = 2
    case paused    = 3
    case unloading = 4
    case pausing   = 5
    case resuming  = 6

    public var description: String {
        switch self {
        case .unloaded:  return "unloaded"
        case .loading:   return "loading"
        case .ready:     return "ready"
        case .paused:    return "paused"
        case .unloading: return "unloading"
        case .pausing:   return "pausing"
        case .resuming:  return "resuming"
        }
    }
}

/// Describes what the currently loaded model is able to do.
///
/// Multimodal flags (`hasMultimodal`, `supportsVision`, `supportsAudio`) are
/// populated when an `mmproj` projector is provided at load time and the
/// projector's backbone reports support for the corresponding modality.
///
/// Tool-call and reasoning flags are derived from the jinja chat template
/// shipped with the model (or the override passed via
/// `ModelConfig.chatTemplateOverride`). They reflect what the template can
/// render/parse, not whether the underlying weights were fine-tuned for the
/// feature — a model without a tool-call-aware template will report
/// `supportsToolCalls == false` even if it "knows" how to call tools.
///
/// Values are captured once at `load()` and kept across `pause()`/`resume()`.
public struct EngineCapabilities: Sendable, Equatable {
    /// True when an mmproj has been loaded alongside the base model.
    public var hasMultimodal: Bool
    /// True when the loaded projector accepts image inputs.
    public var supportsVision: Bool
    /// True when the loaded projector accepts audio inputs (wav/mp3).
    public var supportsAudio: Bool
    /// True when the loaded chat template can render assistant `tool_calls`
    /// (i.e. the model/template pair is usable for OpenAI-style tool calling).
    public var supportsToolCalls: Bool
    /// True when the model can emit reasoning ("thinking") output such as
    /// `<think>…</think>` blocks. Derived from llama.cpp's
    /// `common_chat_templates_support_enable_thinking()` and the differential
    /// autoparser, so it correctly covers Gemma, Ministral, Qwen3,
    /// DeepSeek-R1 distills, gpt-oss, GLM, etc.
    public var supportsReasoning: Bool
    /// True when the loaded chat template **re-injects** a prior assistant
    /// `reasoning_content` field into the rendered prompt on the next turn.
    /// This is rare (Qwen3 recent, GLM-4.5, gpt-oss, DeepSeek-V3.1…) and is
    /// only useful if you want to carry the model's chain-of-thought across
    /// turns. Most reasoning-capable models are `supportsReasoning == true`
    /// but `supportsPreserveReasoning == false`: you should drop
    /// `reasoning_content` from history before re-rendering the prompt.
    public var supportsPreserveReasoning: Bool

    public init(hasMultimodal: Bool = false,
                supportsVision: Bool = false,
                supportsAudio: Bool = false,
                supportsToolCalls: Bool = false,
                supportsReasoning: Bool = false,
                supportsPreserveReasoning: Bool = false) {
        self.hasMultimodal             = hasMultimodal
        self.supportsVision            = supportsVision
        self.supportsAudio             = supportsAudio
        self.supportsToolCalls         = supportsToolCalls
        self.supportsReasoning         = supportsReasoning
        self.supportsPreserveReasoning = supportsPreserveReasoning
    }

    public static let none = EngineCapabilities()
}
