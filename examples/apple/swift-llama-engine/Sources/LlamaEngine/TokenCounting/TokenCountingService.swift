import Foundation

public final class TokenCountingService: @unchecked Sendable {
    private let engine: LlamaEngine

    init(engine: LlamaEngine) {
        self.engine = engine
    }

    public func chatCompletionInputTokens(requestJSON: String) async throws -> TokenCountResult {
        let raw = try await Task.detached(priority: .userInitiated) {
            try self.engine.countChatTokensSync(requestJSON: requestJSON)
        }.value
        return try TokenCountDecoder.decode(raw)
    }
}
