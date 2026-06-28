import Foundation

enum ToolRegistry {
  static let all: [ToolDefinition] = [
    timeTool,
    calculatorTool,
  ]

  /// Serializes the registry into an OAI-compatible `tools` array.
  static func oaiToolsArray() -> [[String: Any]] {
    all.map { tool in
      [
        "type": "function",
        "function": [
          "name":        tool.name,
          "description": tool.description,
          "parameters":  tool.parametersSchema,
        ],
      ]
    }
  }

  static func find(_ name: String) -> ToolDefinition? {
    all.first(where: { $0.name == name })
  }

  // MARK: - Tools

  private static let timeTool = ToolDefinition(
    name: "get_current_time",
    description: "Returns the current date and time (ISO 8601). Optionally in a specific IANA timezone.",
    parametersSchema: [
      "type": "object",
      "properties": [
        "timezone": [
          "type": "string",
          "description": "IANA timezone identifier, e.g. 'Europe/Paris' or 'UTC'. Defaults to the system timezone.",
        ],
      ],
      "required": [] as [String],
    ],
    execute: { args in
      var tz = TimeZone.current
      if let data = args.data(using: .utf8),
         let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let id   = obj["timezone"] as? String,
         let parsed = TimeZone(identifier: id) {
        tz = parsed
      }
      let fmt = ISO8601DateFormatter()
      fmt.timeZone = tz
      fmt.formatOptions = [.withInternetDateTime]
      let payload: [String: Any] = [
        "now":      fmt.string(from: Date()),
        "timezone": tz.identifier,
      ]
      return jsonString(payload)
    }
  )

  private static let calculatorTool = ToolDefinition(
    name: "calculator",
    description: "Evaluates a simple arithmetic expression (+, -, *, /, parentheses) and returns the numeric result.",
    parametersSchema: [
      "type": "object",
      "properties": [
        "expression": [
          "type": "string",
          "description": "Arithmetic expression, e.g. '3 * (4 + 5) / 2'.",
        ],
      ],
      "required": ["expression"],
    ],
    execute: { args in
      guard let data = args.data(using: .utf8),
            let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw  = obj["expression"] as? String else {
        return jsonString(["error": "missing 'expression'"])
      }
      let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)

      // NSExpression accepts function names, so keep only arithmetic tokens.
      let allowed = CharacterSet(charactersIn: "0123456789+-*/().eE. ")
      if expr.rangeOfCharacter(from: allowed.inverted) != nil {
        return jsonString(["error": "invalid characters in expression", "expression": expr])
      }

      let expression = NSExpression(format: expr)
      if let value = expression.expressionValue(with: nil, context: nil) {
        return jsonString(["result": "\(value)", "expression": expr])
      }
      return jsonString(["error": "cannot evaluate", "expression": expr])
    }
  )

  // MARK: - Helpers

  private static func jsonString(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let s = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return s
  }
}
