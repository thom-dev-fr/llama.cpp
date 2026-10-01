import Foundation
import FoundationModels

/// Translation of a `GenerationSchema` into the JSON schema given to the
/// engine's grammar converter, with no silent approximation.
///
/// The engine request also sets `strict_json_schema`: a pattern outside the
/// converter's regex subset fails there, in the same converter that builds the
/// grammar. Here, before any computation:
/// - only the keywords of the SDK's encoding are accepted;
/// - floating-point bounds are refused (the grammar does not enforce them);
/// - patterns are anchored (a guide constrains the whole string) and `\d`,
///   `\w`, `\s` become their ASCII classes, a subset of what Swift's Unicode
///   classes accept; their negations, which would widen, are refused;
/// - a recursive reference to the root (`"$ref": "#"`) becomes a definition;
/// - properties follow the declaration order (`x-order`).
struct SchemaTranslation {
    /// The schema is not representable. `schemaName` locates the refused
    /// constraint for `LanguageModelError.unsupportedGenerationGuide`.
    struct Refusal: Error, Equatable {
        var schemaName: String
        var reason: String

        var languageModelError: LanguageModelError {
            .unsupportedGenerationGuide(.init(schemaName: schemaName, debugDescription: reason))
        }
    }

    static let keywords: Set<String> = [
        "$defs", "$ref", "additionalProperties", "anyOf", "description", "enum", "items", "maxItems", "minItems",
        "maximum", "minimum", "pattern", "properties", "required", "title", "type", "x-order",
    ]

    static func translate(_ schema: GenerationSchema) throws -> JSONValue {
        let encoded = try JSONValue(parsing: JSONEncoder().encode(schema))
        return try translate(encoded, name: schema.name)
    }

    static func translate(_ root: JSONValue, name: String) throws -> JSONValue {
        guard var members = root.objectValue else {
            throw Refusal(schemaName: name, reason: "the schema is not a JSON object")
        }
        var definitions = members.first { $0.0 == "$defs" }?.1.objectValue ?? []
        members.removeAll { $0.0 == "$defs" }
        let rootName = members.first { $0.0 == "title" }?.1.stringValue ?? name

        // "$ref": "#" (recursion through the root): the converter only resolves
        // "#/...", so the root becomes a definition referenced from the top.
        var rootReference: String?
        if references(JSONValue.object(members), "#") || definitions.contains(where: { references($0.1, "#") }) {
            var definitionName = rootName.isEmpty ? "Root" : rootName
            while definitions.contains(where: { $0.0 == definitionName }) {
                definitionName += "_"
            }
            rootReference = "#/$defs/\(definitionName)"
            definitions.append((definitionName, .object(members)))
            members = [("$ref", .string("#"))]
        }

        var context = Context(schemaName: rootName, rootReference: rootReference)
        let translatedDefinitions = try definitions.map { name, value -> (String, JSONValue) in
            context.schemaName = name
            return (name, try context.node(value, path: "$defs/\(name)"))
        }
        context.schemaName = rootName
        guard case var .object(translated) = try context.node(.object(members), path: "#") else {
            throw Refusal(schemaName: rootName, reason: "the schema is not a JSON object")
        }
        if !translatedDefinitions.isEmpty {
            translated.append(("$defs", .object(translatedDefinitions)))
        }
        return .object(translated)
    }

    private static func references(_ value: JSONValue, _ target: String) -> Bool {
        switch value {
        case let .object(members):
            return members.contains { ($0.0 == "$ref" && $0.1.stringValue == target) || references($0.1, target) }
        case let .array(values):
            return values.contains { references($0, target) }
        default:
            return false
        }
    }

    private struct Context {
        var schemaName: String
        var rootReference: String?

        func refuse(_ path: String, _ reason: String) -> Refusal {
            Refusal(schemaName: schemaName, reason: "\(path): \(reason)")
        }

        func node(_ value: JSONValue, path: String) throws -> JSONValue {
            guard let members = value.objectValue else {
                throw refuse(path, "a schema must be a JSON object")
            }
            for (key, _) in members where !SchemaTranslation.keywords.contains(key) {
                throw refuse(path, "the keyword '\(key)' has no grammar translation")
            }
            let type = members.first { $0.0 == "type" }?.1.stringValue
            if type == "number", members.contains(where: { $0.0 == "minimum" || $0.0 == "maximum" }) {
                throw refuse(path, "a range on a floating-point value is not enforced by the grammar")
            }
            let order = members.first { $0.0 == "x-order" }?.1.arrayValue?.compactMap(\.stringValue) ?? []

            var out: [(String, JSONValue)] = []
            for (key, value) in members {
                switch key {
                case "x-order":
                    continue
                case "$ref":
                    if value.stringValue == "#", let rootReference {
                        out.append((key, .string(rootReference)))
                    } else {
                        out.append((key, value))
                    }
                case "pattern":
                    guard let pattern = value.stringValue else {
                        throw refuse(path, "the pattern is not a string")
                    }
                    out.append((key, .string(try SchemaTranslation.pattern(pattern, refuse: { refuse(path, $0) }))))
                case "properties":
                    guard let properties = value.objectValue else {
                        throw refuse(path, "properties must be an object")
                    }
                    let ordered = properties.sorted { lhs, rhs in
                        let l = order.firstIndex(of: lhs.0) ?? Int.max, r = order.firstIndex(of: rhs.0) ?? Int.max
                        return l != r ? l < r : lhs.0 < rhs.0
                    }
                    out.append((key, .object(try ordered.map { ($0.0, try node($0.1, path: "\(path)/\($0.0)")) })))
                case "items":
                    out.append((key, try node(value, path: "\(path)[]")))
                case "anyOf":
                    guard let alternatives = value.arrayValue else {
                        throw refuse(path, "anyOf must be an array")
                    }
                    out.append((key, .array(try alternatives.enumerated().map {
                        try node($0.element, path: "\(path)|\($0.offset)")
                    })))
                case "required":
                    // in declaration order, for a stable rendering
                    let required = value.arrayValue?.compactMap(\.stringValue) ?? []
                    let sorted = required.sorted { (order.firstIndex(of: $0) ?? Int.max, $0) < (order.firstIndex(of: $1) ?? Int.max, $1) }
                    out.append((key, .array(sorted.map { .string($0) })))
                default:
                    out.append((key, value))
                }
            }
            // a canonical key order keeps the serialization stable
            return .object(out.sorted { $0.0 < $1.0 })
        }
    }

    /// Anchors a Swift regex source and rewrites the shorthand classes the
    /// grammar converter does not know.
    static func pattern(_ source: String, refuse: (String) -> Refusal) throws -> String {
        var out = ""
        var inClass = false
        var characters = source.makeIterator()
        while let character = characters.next() {
            if character == "\\" {
                guard let escaped = characters.next() else {
                    throw refuse("the pattern \(source) ends with a backslash")
                }
                switch escaped {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "w": out += inClass ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
                case "s": out += inClass ? " \\t\\n\\r" : "[ \\t\\n\\r]"
                case "D", "W", "S", "b", "B", "p", "P":
                    throw refuse("the pattern \(source) uses \\\(escaped), which the grammar cannot represent exactly")
                default:
                    out += "\\\(escaped)"
                }
                continue
            }
            if character == "[" && !inClass {
                inClass = true
            } else if character == "]" && inClass {
                inClass = false
            }
            out.append(character)
        }
        if out.hasPrefix("^") && out.hasSuffix("$") && !out.hasSuffix("\\$") {
            return out
        }
        return "^(?:\(out))$"
    }
}
