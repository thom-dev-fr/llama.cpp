/// Metadata values emitted through Foundation Models transcript-entry metadata updates.
public typealias LlamaOpenAICompatibleMetadataValues = [String: any Sendable & Codable & Equatable]

/// A typed key for llama.cpp-specific metadata values.
public struct LlamaOpenAICompatibleMetadataKey<Value>: Sendable where Value: Sendable & Codable & Equatable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A small typed wrapper around Foundation Models metadata dictionaries.
public struct LlamaOpenAICompatibleMetadata: Sendable {
    public var values: LlamaOpenAICompatibleMetadataValues

    public init(_ values: LlamaOpenAICompatibleMetadataValues = [:]) {
        self.values = values
    }

    public mutating func set<Value>(
        _ value: Value,
        for key: LlamaOpenAICompatibleMetadataKey<Value>
    ) where Value: Sendable & Codable & Equatable {
        values[key.rawValue] = value
    }
}

/// llama.cpp timing telemetry emitted by local engine and llama-server streams.
public struct LlamaTimings: Codable, Equatable, Sendable {
    public var cachedTokens: Int?
    public var promptMilliseconds: Double?
    public var promptTokens: Int?
    public var promptMillisecondsPerToken: Double?
    public var promptTokensPerSecond: Double?
    public var predictedMilliseconds: Double?
    public var predictedTokens: Int?
    public var predictedMillisecondsPerToken: Double?
    public var predictedTokensPerSecond: Double?
    public var draftTokens: Int?
    public var acceptedDraftTokens: Int?

    public init(
        cachedTokens: Int? = nil,
        promptMilliseconds: Double? = nil,
        promptTokens: Int? = nil,
        promptMillisecondsPerToken: Double? = nil,
        promptTokensPerSecond: Double? = nil,
        predictedMilliseconds: Double? = nil,
        predictedTokens: Int? = nil,
        predictedMillisecondsPerToken: Double? = nil,
        predictedTokensPerSecond: Double? = nil,
        draftTokens: Int? = nil,
        acceptedDraftTokens: Int? = nil
    ) {
        self.cachedTokens = cachedTokens
        self.promptMilliseconds = promptMilliseconds
        self.promptTokens = promptTokens
        self.promptMillisecondsPerToken = promptMillisecondsPerToken
        self.promptTokensPerSecond = promptTokensPerSecond
        self.predictedMilliseconds = predictedMilliseconds
        self.predictedTokens = predictedTokens
        self.predictedMillisecondsPerToken = predictedMillisecondsPerToken
        self.predictedTokensPerSecond = predictedTokensPerSecond
        self.draftTokens = draftTokens
        self.acceptedDraftTokens = acceptedDraftTokens
    }

    private enum CodingKeys: String, CodingKey {
        case cachedTokens = "cache_n"
        case promptMilliseconds = "prompt_ms"
        case promptTokens = "prompt_n"
        case promptMillisecondsPerToken = "prompt_per_token_ms"
        case promptTokensPerSecond = "prompt_per_second"
        case predictedMilliseconds = "predicted_ms"
        case predictedTokens = "predicted_n"
        case predictedMillisecondsPerToken = "predicted_per_token_ms"
        case predictedTokensPerSecond = "predicted_per_second"
        case draftTokens = "draft_n"
        case acceptedDraftTokens = "draft_n_accepted"
    }
}

/// llama.cpp prompt-processing progress telemetry.
public struct LlamaPromptProgress: Codable, Equatable, Sendable {
    public var processedTokens: Int?
    public var totalTokens: Int?
    public var cachedTokens: Int?
    public var elapsedMilliseconds: Double?
    public var fraction: Double?

    public init(
        processedTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedTokens: Int? = nil,
        elapsedMilliseconds: Double? = nil,
        fraction: Double? = nil
    ) {
        self.processedTokens = processedTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
        self.elapsedMilliseconds = elapsedMilliseconds
        self.fraction = fraction
    }

    public init(from decoder: any Decoder) throws {
        if let numeric = try? decoder.singleValueContainer().decode(Double.self) {
            self.init(fraction: numeric)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processedTokens = try container.decodeIfPresent(Int.self, forKey: .processedTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .processed)
        let totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .total)
        let fraction = try container.decodeIfPresent(Double.self, forKey: .fraction)
            ?? container.decodeIfPresent(Double.self, forKey: .progress)
            ?? Self.fraction(processedTokens: processedTokens, totalTokens: totalTokens)

        self.init(
            processedTokens: processedTokens,
            totalTokens: totalTokens,
            cachedTokens: try container.decodeIfPresent(Int.self, forKey: .cachedTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .cache),
            elapsedMilliseconds: try container.decodeIfPresent(Double.self, forKey: .elapsedMilliseconds)
                ?? container.decodeIfPresent(Double.self, forKey: .timeMilliseconds),
            fraction: fraction
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(processedTokens, forKey: .processedTokens)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(cachedTokens, forKey: .cachedTokens)
        try container.encodeIfPresent(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        try container.encodeIfPresent(fraction, forKey: .fraction)
    }

    private static func fraction(processedTokens: Int?, totalTokens: Int?) -> Double? {
        guard let processedTokens, let totalTokens, totalTokens > 0 else { return nil }
        return Double(processedTokens) / Double(totalTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case processedTokens = "processed_tokens"
        case totalTokens = "total_tokens"
        case cachedTokens = "cached_tokens"
        case elapsedMilliseconds = "elapsed_ms"
        case fraction
        case progress
        case processed
        case total
        case cache
        case timeMilliseconds = "time_ms"
    }
}

/// Metadata keys emitted by the shared llama.cpp OpenAI-compatible stream codec.
public enum LlamaTelemetryMetadataKeys {
    public static let timings = LlamaOpenAICompatibleMetadataKey<LlamaTimings>(
        "llama.timings"
    )

    public static let promptProgress = LlamaOpenAICompatibleMetadataKey<LlamaPromptProgress>(
        "llama.prompt_progress"
    )
}

public typealias LlamaServerTimings = LlamaTimings
public typealias LlamaServerPromptProgress = LlamaPromptProgress

/// Compatibility namespace for callers that still use the server-specific name.
public enum LlamaServerMetadataKeys {
    public static let timings = LlamaTelemetryMetadataKeys.timings
    public static let promptProgress = LlamaTelemetryMetadataKeys.promptProgress
}

@available(iOS 27.0, macOS 27.0, *)
public struct LlamaOpenAICompatibleTelemetryFields: Decodable, Sendable {
    public let timings: LlamaTimings?
    public let promptProgress: LlamaPromptProgress?

    public var metadata: LlamaOpenAICompatibleMetadata? {
        var metadata = LlamaOpenAICompatibleMetadata()
        if let timings {
            metadata.set(timings, for: LlamaTelemetryMetadataKeys.timings)
        }
        if let promptProgress {
            metadata.set(promptProgress, for: LlamaTelemetryMetadataKeys.promptProgress)
        }
        return metadata.values.isEmpty ? nil : metadata
    }

    private enum CodingKeys: String, CodingKey {
        case timings
        case promptProgress = "prompt_progress"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timings = try container.decodeIfPresent(LlamaTimings.self, forKey: .timings)
        promptProgress = try container.decodeIfPresent(LlamaPromptProgress.self, forKey: .promptProgress)
    }
}
