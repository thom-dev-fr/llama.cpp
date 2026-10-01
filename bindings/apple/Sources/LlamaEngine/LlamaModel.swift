import CryptoKit
import Foundation

/// Identity of a model artifact in the runtime catalog. Letters, digits, `.`,
/// `_` and `-` (at most 128, not starting with `.`), so that it can name a
/// directory of the model store.
public struct LlamaModelID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public var isValid: Bool {
        !rawValue.isEmpty && rawValue.utf8.count <= 128 && !rawValue.hasPrefix(".") &&
            rawValue.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    public static func < (lhs: LlamaModelID, rhs: LlamaModelID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The files of a model: GGUF weights (one file, or every shard of a split
/// model, first shard first) and an optional multimodal projector.
///
/// An artifact says what can be loaded; a `LlamaLoadProfile` says how. The
/// same artifact loaded with two profiles gives two independent instances.
public struct LlamaModelArtifact: Hashable, Sendable {
    public var id: LlamaModelID
    public var displayName: String
    /// Weight files; llama.cpp opens the first and finds the other shards next to it.
    public var weights: [URL]
    public var projector: URL?
    /// The copy belongs to a `LlamaModelStore`: removing the model deletes it.
    /// Otherwise the files are the application's and are never deleted.
    public var isManaged: Bool

    public init(id: LlamaModelID, displayName: String? = nil, weights: [URL], projector: URL? = nil, isManaged: Bool = false) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.weights = weights
        self.projector = projector
        self.isManaged = isManaged
    }
}

/// How the computation of a loaded model runs.
public struct LlamaComputeConfiguration: Hashable, Sendable {
    public enum Offload: Hashable, Sendable {
        /// CPU only (the projector too).
        case none
        /// llama.cpp chooses from the device memory.
        case automatic
        case all
        case layers(Int)
    }

    public enum FlashAttention: String, Hashable, Sendable {
        case automatic = "auto", enabled = "on", disabled = "off"
    }

    public var offload: Offload
    /// CPU threads; nil keeps the engine default.
    public var threads: Int?
    /// Logical and physical batch sizes; nil keeps the engine default.
    public var batchSize: Int?
    public var microBatchSize: Int?
    public var flashAttention: FlashAttention

    public init(offload: Offload = .all, threads: Int? = nil, batchSize: Int? = nil, microBatchSize: Int? = nil,
                flashAttention: FlashAttention = .automatic) {
        self.offload = offload
        self.threads = threads
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.flashAttention = flashAttention
    }

    var gpuLayers: Int {
        switch offload {
        case .none: return 0
        case .automatic: return -1
        case .all: return -2
        case .layers(let count): return count
        }
    }
}

/// Settings that change the loaded resources of a model. Sessions using the
/// same artifact and the same profile share one loaded instance; two different
/// profiles never share one.
public struct LlamaLoadProfile: Hashable, Sendable {
    /// Context window of each generation, in tokens.
    public var contextSize: Int
    public var compute: LlamaComputeConfiguration
    /// Loads the artifact's projector (images); without it, image input fails.
    public var usesProjector: Bool
    /// Chat template name or Jinja source; nil uses the model's template.
    public var chatTemplate: String?
    /// Other engine options of the model, named as in llama.cpp preset files
    /// (`"cache-type-k": "q8_0"`). An option that repeats a typed setting,
    /// or belongs to the host, makes the load fail with `invalid_config`.
    public var engineOptions: [String: String]

    public init(contextSize: Int = 4096, compute: LlamaComputeConfiguration = LlamaComputeConfiguration(),
                usesProjector: Bool = false, chatTemplate: String? = nil, engineOptions: [String: String] = [:]) {
        self.contextSize = contextSize
        self.compute = compute
        self.usesProjector = usesProjector
        self.chatTemplate = chatTemplate
        self.engineOptions = engineOptions
    }
}

/// One loadable instance of the native catalog: an artifact with a profile.
struct InstanceKey: Hashable, Sendable {
    var model: LlamaModelID
    var profile: LlamaLoadProfile

    /// Native catalog identifier: stable for the same artifact and profile.
    var entryID: String {
        var description = "\(profile.contextSize)|\(profile.compute.gpuLayers)|\(profile.compute.threads ?? -1)|"
        description += "\(profile.compute.batchSize ?? -1)|\(profile.compute.microBatchSize ?? -1)|"
        description += "\(profile.compute.flashAttention.rawValue)|\(profile.usesProjector)|\(profile.chatTemplate ?? "")"
        for (name, value) in profile.engineOptions.sorted(by: { $0.key < $1.key }) {
            description += "|\(name)=\(value)"
        }
        let digest = SHA256.hash(data: Data(description.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(model.rawValue)@\(digest)"
    }
}
