import FoundationModels

/// The structured scenario: an answer generated as a `@Generable` value. The
/// adapter turns its schema into a grammar that constrains the output.
@Generable(description: "A short guide to a city")
struct CityGuide {
    @Guide(description: "The name of the city")
    var name: String
    @Guide(description: "The country of the city")
    var country: String
    @Guide(description: "Approximate population", .range(0...50_000_000))
    var population: Int
    @Guide(description: "Famous landmarks", .count(3))
    var landmarks: [String]
    @Guide(description: "One sentence about the city")
    var summary: String
}
