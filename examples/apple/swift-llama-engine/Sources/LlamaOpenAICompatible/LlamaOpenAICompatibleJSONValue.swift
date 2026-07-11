/// A JSON value useful for provider-specific request fields.
public enum LlamaOpenAICompatibleJSONValue: Hashable, Codable, Sendable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case array([LlamaOpenAICompatibleJSONValue])
    case object([String: LlamaOpenAICompatibleJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LlamaOpenAICompatibleJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LlamaOpenAICompatibleJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
