public struct TokenCountResult: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var object: String?
    public var rawJSON: String

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case object
    }

    public init(inputTokens: Int, object: String? = nil, rawJSON: String = "") {
        self.inputTokens = inputTokens
        self.object = object
        self.rawJSON = rawJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        self.object = try c.decodeIfPresent(String.self, forKey: .object)
        self.rawJSON = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encodeIfPresent(object, forKey: .object)
    }
}
