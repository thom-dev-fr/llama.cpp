import Foundation

/// Inputs used by the metadata-only memory estimator. Prefer
/// `ModelInfo.estimatedMemoryUsage(config:)` when a full `ModelConfig` is
/// available.
public struct MemoryEstimateParameters: Sendable, Hashable, Codable {
    public var contextSize: Int
    public var parallelSlots: Int
    public var kvCacheType: ModelConfig.KVCacheType
    public var includeProjector: Bool
    public var flashAttention: Bool
    public var enableMTP: Bool
    public var mtpDraftNMax: Int

    public init(contextSize: Int,
                parallelSlots: Int = 1,
                kvCacheType: ModelConfig.KVCacheType,
                includeProjector: Bool = true,
                flashAttention: Bool = false,
                enableMTP: Bool = false,
                mtpDraftNMax: Int = 3) {
        self.contextSize = contextSize
        self.parallelSlots = max(1, parallelSlots)
        self.kvCacheType = kvCacheType
        self.includeProjector = includeProjector
        self.flashAttention = flashAttention
        self.enableMTP = enableMTP
        self.mtpDraftNMax = max(1, mtpDraftNMax)
    }

    public init(config: ModelConfig, includeProjector: Bool? = nil) {
        self.init(
            contextSize: Int(config.contextSize),
            parallelSlots: Int(config.parallelSlots),
            kvCacheType: config.kvCacheType,
            includeProjector: includeProjector ?? (config.mtmdProjectorPath != nil),
            flashAttention: config.flashAttention,
            enableMTP: config.enableMTP,
            mtpDraftNMax: Self.mtpDraftNMax(from: config.extraJSON) ?? 3
        )
    }

    private static func mtpDraftNMax(from extraJSON: String?) -> Int? {
        guard let extraJSON,
              let data = extraJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mtp = root["mtp"] as? [String: Any] else { return nil }
        return mtp["n_max"] as? Int
    }
}

