import Foundation

/// Memory measured by the native engine for a configuration, from
/// ``LlamaEngine/measureMemory(for:)``.
///
/// Unlike ``MemoryEstimate``, these values come from llama.cpp creating the
/// model, its context, the multimodal projector and the MTP draft context
/// without allocating them. Weights and KV cache match a loaded context;
/// compute buffers are an upper bound. ``coverage`` and ``isComplete`` say
/// which part could not be measured. This is not the process memory
/// footprint, and device free memory can change before a load.
public struct NativeMemoryReport: Sendable, Hashable, Decodable {
    /// One device, the host, or a separate buffer type. Rows do not overlap.
    public struct Row: Sendable, Hashable, Decodable {
        public enum Kind: String, Sendable, Hashable, Decodable {
            case device
            case host
            case bufferType = "buffer_type"
            case unknown

            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .unknown
            }
        }

        public var kind: Kind
        public var name: String
        public var description: String?
        public var modelBytes: UInt64
        public var contextBytes: UInt64
        public var computeBytes: UInt64
        /// Device capacity, not part of the requirement.
        public var deviceTotalBytes: UInt64?
        /// Device free memory at measurement time, not part of the requirement.
        public var deviceFreeBytes: UInt64?

        public var totalBytes: UInt64 { modelBytes + contextBytes + computeBytes }

        enum CodingKeys: String, CodingKey {
            case kind, name, description
            case modelBytes = "model_bytes"
            case contextBytes = "context_bytes"
            case computeBytes = "compute_bytes"
            case deviceTotalBytes = "device_total_bytes"
            case deviceFreeBytes = "device_free_bytes"
        }
    }

    /// The values the engine used for the measurement.
    public struct Effective: Sendable, Hashable, Decodable {
        public var contextSize: UInt32
        public var trainingContextSize: UInt32?
        public var batchSize: UInt32?
        public var microBatchSize: UInt32?
        public var sequenceCount: UInt32?
        public var kvUnified: Bool?
        public var typeK: String?
        public var typeV: String?
        public var flashAttention: String?
        public var gpuLayers: Int32?

        enum CodingKeys: String, CodingKey {
            case contextSize = "n_ctx"
            case trainingContextSize = "n_ctx_train"
            case batchSize = "n_batch"
            case microBatchSize = "n_ubatch"
            case sequenceCount = "n_seq_max"
            case kvUnified = "kv_unified"
            case typeK = "type_k"
            case typeV = "type_v"
            case flashAttention = "flash_attention"
            case gpuLayers = "gpu_layers"
        }
    }

    public struct RequiredBytes: Sendable, Hashable, Decodable {
        /// Weights of the main model, with its MTP head.
        public var model: UInt64
        public var context: UInt64
        public var compute: UInt64
        /// The multimodal projector: weights and the compute buffer of its
        /// largest input. `0` without a projector or when it is not measured.
        public var projector: UInt64
        /// Context and compute of the MTP draft context, with the weights of
        /// an external draft model. `0` without MTP or when it is not measured.
        public var mtpDraft: UInt64
        /// All the parts above.
        public var total: UInt64

        enum CodingKeys: String, CodingKey {
            case model, context, compute, projector, total
            case mtpDraft = "mtp_draft"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model     = try c.decode(UInt64.self, forKey: .model)
            context   = try c.decode(UInt64.self, forKey: .context)
            compute   = try c.decode(UInt64.self, forKey: .compute)
            // schema 1 did not measure them
            projector = try c.decodeIfPresent(UInt64.self, forKey: .projector) ?? 0
            mtpDraft  = try c.decodeIfPresent(UInt64.self, forKey: .mtpDraft) ?? 0
            total     = try c.decode(UInt64.self, forKey: .total)
        }
    }

    /// Which parts of the configuration are measured.
    public struct Coverage: Sendable, Hashable, Decodable {
        public var model: Bool
        public var context: Bool
        public var projector: Bool
        public var mtpDraft: Bool

        enum CodingKeys: String, CodingKey {
            case model, context, projector
            case mtpDraft = "mtp_draft"
        }
    }

    public var schemaVersion: Int
    public var effective: Effective
    public var rows: [Row]
    public var requiredBytes: RequiredBytes
    public var coverage: Coverage
    /// `false` when a part of the configuration is not measured.
    public var isComplete: Bool
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case effective, rows, coverage, warnings
        case requiredBytes = "required_bytes"
        case isComplete = "complete"
    }

    /// Decodes a report returned by `llama_engine_measure_memory()`.
    public init(json: String) throws {
        self = try JSONDecoder().decode(NativeMemoryReport.self, from: Data(json.utf8))
    }
}

/// A memory figure with its provenance.
public enum MemoryUsage: Sendable, Hashable {
    /// Measured by the native engine.
    case native(NativeMemoryReport)

    /// Estimated from GGUF metadata because the native measurement failed.
    case estimated(MemoryEstimate, nativeError: String)
}

/// What ``LlamaEngine/memoryUsage(for:fallback:)`` does when the native
/// measurement fails.
public enum MemoryMeasurementFallback: Sendable {
    /// Throw the native error.
    case none

    /// Return the metadata-only estimate of this model, tagged as estimated.
    case estimate(ModelInfo)
}
