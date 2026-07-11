import Foundation

enum TokenCountDecoder {
    static func decode(_ raw: String) throws -> TokenCountResult {
        guard let data = raw.data(using: .utf8) else {
            throw LlamaError.internalError("invalid UTF-8 token count response")
        }
        do {
            var result = try JSONDecoder().decode(TokenCountResult.self, from: data)
            result.rawJSON = raw
            return result
        } catch {
            throw LlamaError.internalError("invalid token count response: \(error)")
        }
    }
}
