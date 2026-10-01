import Foundation
import FoundationModels

// Two local, deterministic tools without external effects. Foundation Models
// runs them when the model calls them and sends their output back to it.

/// Evaluates an arithmetic expression.
struct CalculatorTool: Tool {
    let name = "calculate"
    let description = "Evaluates an arithmetic expression with numbers, + - * /, and parentheses."

    @Generable struct Arguments {
        @Guide(description: "The expression, for example (12+3)*4")
        var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            return ArithmeticExpression.format(try ArithmeticExpression.evaluate(arguments.expression))
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}

/// Looks up a product of a small fictitious shop.
struct ProductLookupTool: Tool {
    let name = "lookup_product"
    let description = "Looks up a product of the demo shop: its price in EUR and the quantity in stock."

    @Generable struct Arguments {
        @Guide(description: "The product name, for example pen")
        var product: String
    }

    struct Product: Sendable {
        var name: String
        var priceInCents: Int
        var stock: Int
    }

    static let products: [Product] = [
        Product(name: "pen", priceInCents: 300, stock: 120),
        Product(name: "notebook", priceInCents: 450, stock: 40),
        Product(name: "backpack", priceInCents: 3900, stock: 7),
        Product(name: "lamp", priceInCents: 2450, stock: 0),
        Product(name: "mug", priceInCents: 800, stock: 25),
    ]

    func call(arguments: Arguments) async throws -> String {
        Self.answer(for: arguments.product)
    }

    static func answer(for query: String) -> String {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let singular = key.hasSuffix("s") ? String(key.dropLast()) : key
        guard let product = products.first(where: { $0.name == key || $0.name == singular }) else {
            return "unknown product '\(query)'; known products: " + products.map(\.name).joined(separator: ", ")
        }
        let price = String(format: "%d.%02d", product.priceInCents / 100, product.priceInCents % 100)
        return "\(product.name): \(price) EUR, \(product.stock) in stock"
    }
}

/// Recursive descent over `+ - * /`, unary minus and parentheses, in Double.
enum ArithmeticExpression {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func evaluate(_ text: String) throws -> Double {
        var parser = Parser(characters: Array(text.filter { !$0.isWhitespace }))
        let value = try parser.sum()
        guard parser.index == parser.characters.count else {
            throw Failure(errorDescription: "unexpected '\(parser.characters[parser.index])'")
        }
        guard value.isFinite else {
            throw Failure(errorDescription: "the result is not a finite number")
        }
        return value
    }

    /// An integer without decimals, otherwise at most 6 decimals.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        mutating func sum() throws -> Double {
            var value = try product()
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                let rhs = try product()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func product() throws -> Double {
            var value = try factor()
            while let op = peek(), op == "*" || op == "/" || op == "×" || op == "÷" {
                index += 1
                let rhs = try factor()
                if op == "*" || op == "×" {
                    value *= rhs
                } else {
                    guard rhs != 0 else { throw Failure(errorDescription: "division by zero") }
                    value /= rhs
                }
            }
            return value
        }

        mutating func factor() throws -> Double {
            guard let next = peek() else { throw Failure(errorDescription: "incomplete expression") }
            if next == "-" {
                index += 1
                return -(try factor())
            }
            if next == "(" {
                index += 1
                let value = try sum()
                guard peek() == ")" else { throw Failure(errorDescription: "missing ')'") }
                index += 1
                return value
            }
            let start = index
            while let c = peek(), c.isNumber || c == "." { index += 1 }
            guard index > start, let value = Double(String(characters[start..<index])) else {
                throw Failure(errorDescription: "expected a number at '\(next)'")
            }
            return value
        }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }
    }
}
