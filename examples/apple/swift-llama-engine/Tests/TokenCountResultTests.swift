import Foundation
import Testing
@testable import LlamaEngine

struct TokenCountResultTests {
    @Test func decodesTokenCountResult() throws {
        let data = Data(#"{"input_tokens":12,"object":"token_count"}"#.utf8)

        let result = try JSONDecoder().decode(TokenCountResult.self, from: data)

        #expect(result.inputTokens == 12)
        #expect(result.object == "token_count")
        #expect(result.rawJSON == "")
    }

    @Test func tokenCountDecoderPreservesRawJSON() throws {
        let raw = #"{"input_tokens":7}"#

        let result = try TokenCountDecoder.decode(raw)

        #expect(result.inputTokens == 7)
        #expect(result.object == nil)
        #expect(result.rawJSON == raw)
    }
}
