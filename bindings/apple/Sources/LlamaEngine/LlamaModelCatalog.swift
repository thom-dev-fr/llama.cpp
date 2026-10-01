import Foundation

/// A versioned manifest of downloadable models.
///
/// Each entry pins its files to an exact source revision, with their size and
/// SHA-256: a download is installed only when every file matches. The entry
/// also records the license, the chat template and two lists of capabilities:
/// those the model announces, and those qualified end to end with this
/// library. Only qualified capabilities may be offered to Foundation Models.
///
/// ```json
/// { "formatVersion": 1, "catalogVersion": "2026-10-01", "models": [ { "id": "...", ... } ] }
/// ```
public struct LlamaModelCatalog: Codable, Hashable, Sendable {
    /// Format understood by this library. A catalog of another format is refused.
    public static let formatVersion = 1

    public var formatVersion: Int
    /// Version of the content, chosen by its publisher.
    public var catalogVersion: String
    public var models: [Entry]

    public init(catalogVersion: String, models: [Entry]) {
        formatVersion = Self.formatVersion
        self.catalogVersion = catalogVersion
        self.models = models
    }

    public subscript(id: LlamaModelID) -> Entry? {
        models.first { $0.id == id }
    }

    /// Decodes and validates a catalog.
    public static func decode(_ data: Data) throws -> LlamaModelCatalog {
        let catalog: LlamaModelCatalog
        do {
            catalog = try JSONDecoder().decode(LlamaModelCatalog.self, from: data)
        } catch {
            throw LlamaEngineError.invalidCatalog("unreadable catalog: \(error)")
        }
        try catalog.validate()
        return catalog
    }

    /// Checks the format version, then every entry; identifiers are unique.
    public func validate() throws {
        guard formatVersion == Self.formatVersion else {
            throw LlamaEngineError.invalidCatalog("catalog format \(formatVersion) is not supported (expected \(Self.formatVersion))")
        }
        var seen: Set<LlamaModelID> = []
        for entry in models {
            try entry.validate()
            guard seen.insert(entry.id).inserted else {
                throw LlamaEngineError.invalidCatalog("duplicate model '\(entry.id)'")
            }
        }
    }

    public enum Capability: String, Codable, Hashable, Sendable, CaseIterable {
        case guidedGeneration, toolCalling, reasoning, vision
    }

    /// Where the files come from: a repository at one immutable revision.
    public struct Source: Codable, Hashable, Sendable {
        /// For instance `huggingface.co/unsloth/Qwen3.5-2B-GGUF`.
        public var repository: String
        /// Commit (or other immutable revision); every file URL contains it.
        public var revision: String

        public init(repository: String, revision: String) {
            self.repository = repository
            self.revision = revision
        }
    }

    public struct File: Codable, Hashable, Sendable {
        /// File name in the store (`.gguf`, no directory).
        public var name: String
        public var url: URL
        public var size: Int64
        /// Lowercase hexadecimal SHA-256 of the whole file.
        public var sha256: String

        public init(name: String, url: URL, size: Int64, sha256: String) {
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256
        }
    }

    public struct License: Codable, Hashable, Sendable {
        /// SPDX-like identifier, for instance `apache-2.0`.
        public var identifier: String
        public var url: URL?

        public init(identifier: String, url: URL? = nil) {
            self.identifier = identifier
            self.url = url
        }
    }

    /// The chat template the qualification used.
    public struct ChatTemplate: Codable, Hashable, Sendable {
        /// `embedded` (the GGUF's `tokenizer.chat_template`) or a llama.cpp
        /// template name, passed as `LlamaLoadProfile.chatTemplate`.
        public var source: String
        /// SHA-256 of the embedded Jinja source, when `source` is `embedded`.
        public var sha256: String?

        public init(source: String, sha256: String? = nil) {
            self.source = source
            self.sha256 = sha256
        }

        public var isEmbedded: Bool { source == "embedded" }
    }

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: LlamaModelID
        public var displayName: String
        public var source: Source
        /// Weight files: one file, or every shard of a split model in order.
        public var weights: [File]
        /// Multimodal projector, required for vision.
        public var projector: File?
        public var license: License
        public var chatTemplate: ChatTemplate
        /// Capabilities announced by the model and its template, not verified.
        public var declaredCapabilities: [Capability]
        /// Capabilities verified with this library; a subset of the declared ones.
        public var qualifiedCapabilities: [Capability]
        /// Where the qualification evidence is recorded.
        public var qualification: String?

        public init(id: LlamaModelID, displayName: String, source: Source, weights: [File], projector: File? = nil,
                    license: License, chatTemplate: ChatTemplate, declaredCapabilities: [Capability] = [],
                    qualifiedCapabilities: [Capability] = [], qualification: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.source = source
            self.weights = weights
            self.projector = projector
            self.license = license
            self.chatTemplate = chatTemplate
            self.declaredCapabilities = declaredCapabilities
            self.qualifiedCapabilities = qualifiedCapabilities
            self.qualification = qualification
        }

        /// Weights first, then the projector.
        public var files: [File] { weights + [projector].compactMap { $0 } }

        public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

        public func validate() throws {
            func require(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
                if !condition { throw LlamaEngineError.invalidCatalog("\(id): \(reason())") }
            }
            try require(id.isValid, "invalid model identifier")
            try require(!displayName.isEmpty, "empty display name")
            try require(!source.repository.isEmpty, "empty source repository")
            try require(Self.isRevision(source.revision), "the revision '\(source.revision)' is not an immutable identifier")
            try require(!weights.isEmpty, "no weight file")
            try require(!license.identifier.isEmpty, "no license")
            if chatTemplate.isEmbedded {
                try require(chatTemplate.sha256.map(Self.isSHA256) ?? true, "invalid template SHA-256")
            } else {
                try require(!chatTemplate.source.isEmpty && chatTemplate.sha256 == nil, "a named template has no SHA-256")
            }
            try require(Set(qualifiedCapabilities).isSubset(of: declaredCapabilities),
                        "a qualified capability is not declared")
            try require(!declaredCapabilities.contains(.vision) || projector != nil, "vision without projector")

            var names: Set<String> = []
            for file in files {
                try require(Self.isFileName(file.name), "invalid file name '\(file.name)'")
                try require(names.insert(file.name).inserted, "duplicate file '\(file.name)'")
                try require(file.size > 0, "\(file.name) has no size")
                try require(Self.isSHA256(file.sha256), "\(file.name) has an invalid SHA-256")
                try require(Self.isAllowed(file.url), "\(file.name): \(file.url) is not an https URL")
                try require(file.url.pathComponents.contains(source.revision),
                            "\(file.name): the URL does not reference revision \(source.revision)")
            }
            if weights.count > 1 {
                for (index, file) in weights.enumerated() {
                    let suffix = String(format: "-%05d-of-%05d.gguf", index + 1, weights.count)
                    try require(file.name.hasSuffix(suffix), "\(file.name) is not shard \(index + 1) of \(weights.count)")
                }
            }
        }

        /// A commit-like identifier (7 to 64 hexadecimal digits): a branch or
        /// tag name could move.
        static func isRevision(_ value: String) -> Bool {
            (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
        }

        static func isSHA256(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }

        static func isFileName(_ value: String) -> Bool {
            value.hasSuffix(".gguf") && !value.hasPrefix(".") && value != "manifest.json" &&
                value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        }

        /// https, or http to the loopback interface (local tests).
        static func isAllowed(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "https": return url.host?.isEmpty == false
            case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
            default: return false
            }
        }
    }
}
