import Foundation

/// A model file to import into a `LlamaModelStore`.
public struct LlamaModelImport: Hashable, Sendable {
    public var id: LlamaModelID
    public var displayName: String?
    /// GGUF weights. For a split model (`name-00001-of-00003.gguf`), the first
    /// shard: the other shards are taken from the same directory.
    public var weights: URL
    /// Multimodal projector (GGUF), when the model reads images.
    public var projector: URL?

    public init(id: LlamaModelID, displayName: String? = nil, weights: URL, projector: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.weights = weights
        self.projector = projector
    }
}

/// Models copied into the application's sandbox, one directory per model:
///
/// ```text
/// <root>/models/<id>/manifest.json, weights (all shards), projector
/// <root>/staging/   imports in progress (removed at the next start)
/// <root>/trash/     removals in progress (same)
/// ```
///
/// An import copies the files into `staging`, writes the manifest, then moves
/// the directory into `models` in one rename: a model is either complete or
/// absent. The source files are only read. Model directories are excluded from
/// the system backup (the weights can be imported or downloaded again).
///
/// The runtime serializes imports and removals with loads and generations;
/// use the store through `LlamaRuntime`.
public final class LlamaModelStore: Sendable {
    public let root: URL
    private let availableCapacity: @Sendable (URL) throws -> Int64

    private var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    private var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var trashDirectory: URL { root.appendingPathComponent("trash", isDirectory: true) }

    /// Free space kept on the volume after an import.
    static let reserve: Int64 = 64 << 20

    public convenience init(root: URL) throws {
        try self.init(root: root, availableCapacity: LlamaModelStore.systemAvailableCapacity)
    }

    /// `availableCapacity` reports the free bytes of the volume holding a URL.
    package init(root: URL, availableCapacity: @escaping @Sendable (URL) throws -> Int64) throws {
        self.root = root
        self.availableCapacity = availableCapacity
        let manager = FileManager.default
        for directory in [modelsDirectory, stagingDirectory, trashDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Leftovers of an interrupted import or removal.
        for directory in [stagingDirectory, trashDirectory] {
            for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try? manager.removeItem(at: item)
            }
        }
    }

    /// The store in Application Support, created if needed.
    public static func applicationSupport(subdirectory: String = "LlamaModels") throws -> LlamaModelStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try LlamaModelStore(root: base.appendingPathComponent(subdirectory, isDirectory: true))
    }

    static func systemAvailableCapacity(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    struct Manifest: Codable {
        var version = 1
        var id: LlamaModelID
        var displayName: String
        var weights: [String]
        var projector: String?
        var bytes: Int64
        var importedAt: Date
    }

    /// Models of the store; a directory without a readable manifest is ignored.
    public func artifacts() throws -> [LlamaModelArtifact] {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var artifacts: [LlamaModelArtifact] = []
        for directory in try manager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data),
                  manifest.id.rawValue == directory.lastPathComponent else {
                continue
            }
            artifacts.append(artifact(manifest, in: self.directory(of: manifest.id)))
        }
        return artifacts.sorted { $0.id < $1.id }
    }

    private func artifact(_ manifest: Manifest, in directory: URL) -> LlamaModelArtifact {
        LlamaModelArtifact(id: manifest.id, displayName: manifest.displayName,
                           weights: manifest.weights.map { directory.appendingPathComponent($0) },
                           projector: manifest.projector.map { directory.appendingPathComponent($0) },
                           isManaged: true)
    }

    func directory(of id: LlamaModelID) -> URL {
        modelsDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// Copies a model into the store (blocking; the runtime calls it on a
    /// worker). `isCancelled` is checked between files.
    func importModel(_ request: LlamaModelImport, isCancelled: () -> Bool) throws -> LlamaModelArtifact {
        guard request.id.isValid else {
            throw LlamaEngineError.invalidConfiguration("invalid model identifier '\(request.id)'")
        }
        let manager = FileManager.default
        let target = directory(of: request.id)
        guard !manager.fileExists(atPath: target.path) else {
            throw LlamaEngineError.modelExists(request.id)
        }
        // Files picked by the user may be security scoped.
        let scoped = [request.weights, request.projector].compactMap { $0 }.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let weights = try Self.shards(of: request.weights)
        var sources = weights
        if let projector = request.projector {
            guard !weights.map(\.lastPathComponent).contains(projector.lastPathComponent) else {
                throw LlamaEngineError.invalidModelFile("the projector has the name of a weight file")
            }
            sources.append(projector)
        }
        var bytes: Int64 = 0
        for source in sources {
            bytes += try Self.checkGGUF(source)
        }
        let available = try availableCapacity(root)
        guard available >= bytes + Self.reserve else {
            throw LlamaEngineError.insufficientSpace(required: bytes + Self.reserve, available: available)
        }

        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for source in sources {
                guard !isCancelled() else { throw CancellationError() }
                // A clone on APFS, a copy otherwise; the source is only read.
                try manager.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
            }
            guard !isCancelled() else { throw CancellationError() }
            let manifest = Manifest(id: request.id, displayName: request.displayName ?? request.id.rawValue,
                                    weights: weights.map(\.lastPathComponent),
                                    projector: request.projector?.lastPathComponent,
                                    bytes: bytes, importedAt: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = staging
            try excluded.setResourceValues(values)
            // The rename makes the model appear complete, or fails if another
            // import of the same identifier finished first.
            if rename(staging.path, target.path) != 0 {
                let code = errno
                if code == EEXIST || code == ENOTEMPTY {
                    throw LlamaEngineError.modelExists(request.id)
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return artifact(manifest, in: target)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Deletes the managed copy of a model: one rename out of `models`, then
    /// the files. Never touches the files an import was made from.
    func remove(_ id: LlamaModelID) throws {
        let manager = FileManager.default
        let source = directory(of: id)
        guard manager.fileExists(atPath: source.path) else { return }
        let trash = trashDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.moveItem(at: source, to: trash)
        try? manager.removeItem(at: trash)
    }

    /// The weight files of a model: the file itself, or every shard of a split
    /// model announced by its name (`-00001-of-00003.gguf`).
    static func shards(of first: URL) throws -> [URL] {
        let name = first.lastPathComponent
        guard let match = name.wholeMatch(of: /(.+)-(\d{5})-of-(\d{5})\.gguf/) else {
            return [first]
        }
        let index = Int(match.output.2)!
        let count = Int(match.output.3)!
        guard index == 1, count >= 1 else {
            throw LlamaEngineError.invalidModelFile("\(name) is not the first shard of its model")
        }
        let directory = first.deletingLastPathComponent()
        return try (1...count).map { shard in
            let url = directory.appendingPathComponent(String(format: "%@-%05d-of-%05d.gguf", String(match.output.1), shard, count))
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw LlamaEngineError.invalidModelFile("missing shard \(url.lastPathComponent)")
            }
            return url
        }
    }

    /// Checks the GGUF magic and returns the file size.
    static func checkGGUF(_ url: URL) throws -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LlamaEngineError.invalidModelFile("cannot read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        guard let magic = try handle.read(upToCount: 4), magic == Data("GGUF".utf8) else {
            throw LlamaEngineError.invalidModelFile("\(url.lastPathComponent) is not a GGUF file")
        }
        let size = try handle.seekToEnd()
        return Int64(size)
    }
}
