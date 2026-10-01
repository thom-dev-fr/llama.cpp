import Foundation

/// The engine boundary of the Foundation Models adapter: `LlamaRuntime` in
/// production, a scripted engine in the adapter's deterministic tests.
package protocol LlamaChatBackend: Sendable {
    /// The artifact of a catalog model, if present.
    func artifact(_ id: LlamaModelID) -> LlamaModelArtifact?

    /// Submits a chat request (engine JSON, without `model`) after admission.
    func chat(model: LlamaModelID, profile: LlamaLoadProfile, body: Data,
              attachments: [NativeAttachment]) async throws -> any LlamaChatEvents

    /// The engine properties of the instance (`chat_template_caps`, ...),
    /// loading it if needed.
    func properties(model: LlamaModelID, profile: LlamaLoadProfile) async throws -> Data
}

/// Events of one submitted chat request: payloads, then the success event,
/// then nil; a failure or cancellation is thrown (see `LlamaGeneration.next`).
package protocol LlamaChatEvents: AnyObject, Sendable {
    func next() async throws -> NativeEvent?
    /// Cancels the native work; the reader then sees the cancellation.
    func cancel()
}

extension LlamaGeneration: LlamaChatEvents {}

extension LlamaRuntime: LlamaChatBackend {
    package func artifact(_ id: LlamaModelID) -> LlamaModelArtifact? {
        snapshot()[id]?.artifact
    }

    package func chat(model: LlamaModelID, profile: LlamaLoadProfile, body: Data,
                      attachments: [NativeAttachment]) async throws -> any LlamaChatEvents {
        try await generate("chat", model: model, profile: profile, body: body, attachments: attachments)
    }
}
