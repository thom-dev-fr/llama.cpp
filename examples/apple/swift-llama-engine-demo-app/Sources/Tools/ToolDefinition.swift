import Foundation

/// Minimal local tool exposed through OpenAI-compatible function calling.
struct ToolDefinition: @unchecked Sendable {
    let name: String
    let description: String
    /// JSON Schema for the tool parameters.
    let parametersSchema: [String: Any]
    /// Synchronous local handler returning the `role:"tool"` payload.
    let execute: @Sendable (String) -> String
}
