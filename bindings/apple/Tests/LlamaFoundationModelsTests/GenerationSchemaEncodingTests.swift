import Foundation
import FoundationModels
import Testing

// P0 contract of the SDK: the schema translation (P5) reads the JSON encoding of
// GenerationSchema. These facts are the ones the grammar conversion depends on;
// a change of the SDK must fail here first.

@Generable private struct Item {
    @Guide(description: "lowercase name", .pattern(/[a-z]+/)) var name: String
    @Guide(.range(1...5)) var quantity: Int
    @Guide(.range(0.5...2.5)) var weight: Double
    var note: String?
}

@Generable private enum Color { case red, green }

@Generable private struct Order {
    @Guide(.count(1...3)) var items: [Item]
    var color: Color
    var paid: Bool
}

private func encoded(_ schema: GenerationSchema) throws -> [String: Any] {
    let data = try JSONEncoder().encode(schema)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct GenerationSchemaEncodingTests {
    @Test func generableEncodesAsJSONSchemaWithDefinitions() throws {
        let root = try encoded(Order.generationSchema)
        print("P0 Order schema: \(String(decoding: try JSONEncoder().encode(Order.generationSchema), as: UTF8.self))")
        #expect(root["type"] as? String == "object")
        #expect(root["additionalProperties"] as? Bool == false)
        #expect(root["x-order"] as? [String] == ["items", "color", "paid"])

        let properties = try #require(root["properties"] as? [String: Any])
        let items = try #require(properties["items"] as? [String: Any])
        #expect(items["minItems"] as? Int == 1)
        #expect(items["maxItems"] as? Int == 3)
        #expect((items["items"] as? [String: Any])?["$ref"] as? String == "#/$defs/Item")
        #expect((properties["color"] as? [String: Any])?["enum"] as? [String] == ["red", "green"])

        let item = try #require((root["$defs"] as? [String: Any])?["Item"] as? [String: Any])
        // Optional properties are left out of "required", not typed as null.
        #expect(Set(item["required"] as? [String] ?? []) == ["name", "quantity", "weight"])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        // Patterns are not anchored: the grammar converter needs ^...$.
        #expect((itemProperties["name"] as? [String: Any])?["pattern"] as? String == "[a-z]+")
        #expect((itemProperties["quantity"] as? [String: Any])?["minimum"] as? Int == 1)
        // Floating-point bounds exist, and the converter ignores them today.
        #expect((itemProperties["weight"] as? [String: Any])?["minimum"] as? Double == 0.5)
    }

    @Test func recursiveRootIsReferencedAsHash() throws {
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Node", properties: [
                .init(name: "next", schema: DynamicGenerationSchema(referenceTo: "Node"), isOptional: true),
                .init(name: "value", schema: DynamicGenerationSchema(type: Int.self)),
            ]),
            dependencies: [])
        let root = try encoded(schema)
        let next = try #require((root["properties"] as? [String: Any])?["next"] as? [String: Any])
        // The converter only resolves "#/..." references today.
        #expect(next["$ref"] as? String == "#")
    }
}
