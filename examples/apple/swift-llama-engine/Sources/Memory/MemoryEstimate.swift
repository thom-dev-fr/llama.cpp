import Foundation

public enum MemoryEstimateConfidence: String, Sendable, Hashable, Codable {
    case high
    case medium
    case low
}

/// Metadata-only memory estimate. `persistentBytes` is the best-effort sum of
/// model/projector weights and persistent cache state. `recommendedCapacityBytes`
/// adds a heuristic runtime overhead for compute buffers and allocator slack.
public struct MemoryEstimate: Sendable, Hashable, Codable {
    public var modelBytes: UInt64
    public var projectorBytes: UInt64
    public var kvCacheBytes: UInt64
    public var mtpBytes: UInt64
    public var runtimeOverheadBytes: UInt64
    public var persistentBytes: UInt64
    public var recommendedCapacityBytes: UInt64
    public var effectiveContextSize: UInt32
    public var confidence: MemoryEstimateConfidence
    public var warnings: [String]

    public init(modelBytes: UInt64,
                projectorBytes: UInt64,
                kvCacheBytes: UInt64,
                mtpBytes: UInt64,
                runtimeOverheadBytes: UInt64,
                effectiveContextSize: UInt32,
                confidence: MemoryEstimateConfidence,
                warnings: [String]) {
        self.modelBytes = modelBytes
        self.projectorBytes = projectorBytes
        self.kvCacheBytes = kvCacheBytes
        self.mtpBytes = mtpBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.persistentBytes = modelBytes + projectorBytes + kvCacheBytes + mtpBytes
        self.recommendedCapacityBytes = self.persistentBytes + runtimeOverheadBytes
        self.effectiveContextSize = effectiveContextSize
        self.confidence = confidence
        self.warnings = warnings
    }
}

