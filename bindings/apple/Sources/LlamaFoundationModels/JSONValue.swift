import Foundation

/// JSON with ordered object keys. Requests are serialized deterministically:
/// the same transcript gives the same bytes, so the rendered prompt (tool
/// schemas included) keeps the prefix the engine may reuse from its cache.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Converts a JSONSerialization value; object keys are sorted.
    init(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = .object(object.keys.sorted().map { ($0, JSONValue(foundation: object[$0]!)) })
        default:
            self = .null
        }
    }

    init(parsing data: Data) throws {
        self.init(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.0 == key }?.1
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.rounded() == value: return Int(exactly: value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [(String, JSONValue)]? {
        if case let .object(value) = self { return value }
        return nil
    }

    // MARK: Serialization

    var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    var data: Data { Data(serialized.utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .int(value): out += String(value)
        case let .double(value):
            if value.isFinite, value.rounded() == value, abs(value) < 1e15 {
                out += String(Int64(value))
            } else {
                out += "\(value)"
            }
        case let .string(value): Self.writeString(value, to: &out)
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (index, (key, value)) in members.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
}
