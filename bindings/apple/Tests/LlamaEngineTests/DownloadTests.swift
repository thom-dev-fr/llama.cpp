import CryptoKit
import Foundation
@testable import LlamaEngine
import Testing

// P4: catalog manifest and URLSession downloads against a controlled local
// server: interruption, resume, restart, errors, integrity, installation.

private let catalogFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Catalog/models.json")

private let revision = "0123456789abcdef0123456789abcdef01234567"
private let model = LlamaModelID("tiny")

/// GGUF magic followed by deterministic bytes.
private func gguf(_ size: Int, seed: UInt8 = 1) -> Data {
    var data = Data("GGUF".utf8)
    data.append(contentsOf: (0..<(size - 4)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    return data
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func catalogFile(_ name: String, _ data: Data, base: URL) -> LlamaModelCatalog.File {
    LlamaModelCatalog.File(name: name, url: base.appendingPathComponent("\(revision)/\(name)"),
                           size: Int64(data.count), sha256: sha256(data))
}

/// A fixture: server, runtime with a store, downloads (foreground session).
private final class Fixture: @unchecked Sendable {
    let server: TestHTTPServer
    let base: URL
    let root: URL
    let runtime: LlamaRuntime
    var downloads: LlamaModelDownloads
    let weights = gguf(600_000, seed: 1)
    let projector = gguf(300_000, seed: 2)

    init(capacity: Int64? = nil) async throws {
        server = try TestHTTPServer()
        base = try await server.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        self.root = root
        let store = try capacity.map { capacity in
            try LlamaModelStore(root: root, availableCapacity: { _ in capacity })
        } ?? LlamaModelStore(root: root)
        runtime = try LlamaRuntime(store: store)
        downloads = try Self.makeDownloads(runtime)
        await downloads.reattached()
        server["/\(revision)/tiny.gguf"] = .init(data: weights, etag: "\"w1\"")
        server["/\(revision)/mmproj.gguf"] = .init(data: projector, etag: "\"p1\"")
        current = self
    }

    static func makeDownloads(_ runtime: LlamaRuntime) throws -> LlamaModelDownloads {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return try LlamaModelDownloads(runtime: runtime, sessionConfiguration: configuration)
    }

    var entry: LlamaModelCatalog.Entry {
        LlamaModelCatalog.Entry(
            id: model, displayName: "Tiny", source: .init(repository: "127.0.0.1/tiny", revision: revision),
            weights: [catalogFile("tiny.gguf", weights, base: base)],
            projector: catalogFile("mmproj.gguf", projector, base: base),
            license: .init(identifier: "mit"), chatTemplate: .init(source: "chatml"),
            declaredCapabilities: [.vision])
    }

    var download: LlamaModelDownload? { downloads.snapshot()[model] }
    var directory: URL { root.appendingPathComponent("downloads/tiny") }

    /// A new instance over the same store, as after a relaunch.
    func relaunch() async throws {
        downloads.session.invalidateAndCancel()
        // A process that ends delivers nothing more; let the old session's
        // last events land before the next instance reads the records.
        try await Task.sleep(for: .milliseconds(300))
        downloads = try Self.makeDownloads(runtime)
        await downloads.reattached()
    }

    func installed() async throws {
        try await until { runtime.snapshot()[model] != nil }
        try await until { download == nil }
    }

    deinit {
        downloads.invalidate()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

nonisolated(unsafe) private var current: Fixture?

private func until(_ timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout); download: \(String(describing: current?.download))",
                         sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func state(_ fixture: Fixture) -> LlamaModelDownload.State? {
    fixture.download?.state
}

@Suite(.serialized) struct DownloadTests {
    // MARK: Catalog

    @Test func shippedCatalogIsValid() throws {
        let catalog = try LlamaModelCatalog.decode(Data(contentsOf: catalogFile))
        #expect(catalog.formatVersion == 1)
        let qwen = try #require(catalog[LlamaModelID("qwen3.5-2b-q4_k_m")])
        #expect(qwen.source.revision == "f6d5376be1edb4d416d56da11e5397a961aca8ae")
        #expect(qwen.weights.map(\.name) == ["Qwen3.5-2B-Q4_K_M.gguf"])
        #expect(qwen.weights[0].size == 1_280_835_840)
        #expect(qwen.weights[0].sha256 == "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")
        #expect(qwen.projector?.sha256 == "f17196c0d8fc756bc65be60075bd4a359917eee8a438505639511727c585d3c2")
        #expect(qwen.license.identifier == "apache-2.0")
        #expect(qwen.chatTemplate.isEmbedded)
        // Nothing is qualified with the adapter yet (P5/P7).
        #expect(qwen.qualifiedCapabilities.isEmpty)
        #expect(Set(qwen.declaredCapabilities) == [.toolCalling, .reasoning, .vision])
    }

    @Test func invalidCatalogsAreRefused() throws {
        let base = URL(string: "https://example.org/repo/resolve")!
        let data = gguf(16)
        let valid = LlamaModelCatalog.Entry(
            id: model, displayName: "Tiny", source: .init(repository: "example.org/repo", revision: revision),
            weights: [catalogFile("tiny.gguf", data, base: base)], license: .init(identifier: "mit"),
            chatTemplate: .init(source: "embedded", sha256: sha256(data)))
        try valid.validate()

        func refused(_ change: (inout LlamaModelCatalog.Entry) -> Void) -> Bool {
            var entry = valid
            change(&entry)
            do {
                try entry.validate()
                return false
            } catch LlamaEngineError.invalidCatalog {
                return true
            } catch {
                return false
            }
        }
        #expect(refused { $0.source.revision = "main" })
        #expect(refused { $0.weights[0].url = URL(string: "https://example.org/repo/resolve/main/tiny.gguf")! })
        #expect(refused { $0.weights[0].url = URL(string: "http://example.org/\(revision)/tiny.gguf")! })
        #expect(refused { $0.weights[0].sha256 = "ABC" })
        #expect(refused { $0.weights[0].size = 0 })
        #expect(refused { $0.weights[0].name = "../tiny.gguf" })
        #expect(refused { $0.weights[0].name = "manifest.json" })
        #expect(refused { $0.declaredCapabilities = [.vision] })                         // no projector
        #expect(refused { $0.qualifiedCapabilities = [.toolCalling] })                   // not declared
        #expect(refused { $0.projector = $0.weights[0] })                                // duplicate name
        #expect(refused { $0.weights.append(catalogFile("tiny-2.gguf", data, base: base)) }) // shard names
        #expect(refused { $0.chatTemplate = .init(source: "chatml", sha256: sha256(data)) })

        let split = ["tiny-00001-of-00002.gguf", "tiny-00002-of-00002.gguf"].map { catalogFile($0, data, base: base) }
        var shards = valid
        shards.weights = split
        try shards.validate()

        var catalog = LlamaModelCatalog(catalogVersion: "test", models: [valid, valid])
        #expect(throws: LlamaEngineError.self) { try catalog.validate() }
        catalog.models = [valid]
        catalog.formatVersion = 2
        #expect(throws: LlamaEngineError.self) { try LlamaModelCatalog.decode(JSONEncoder().encode(catalog)) }
    }

    // MARK: Downloads

    @Test func downloadVerifiesAndInstallsTheWholeSet() async throws {
        let fixture = try await Fixture()
        var updates = fixture.downloads.updates().makeAsyncIterator()
        #expect(await updates.next()?.snapshot.downloads.isEmpty == true)

        try fixture.downloads.start(fixture.entry)
        #expect(fixture.download != nil)
        try await fixture.installed()

        let artifact = try #require(fixture.runtime.snapshot()[model]?.artifact)
        #expect(artifact.isManaged)
        #expect(artifact.catalogEntry == fixture.entry)
        #expect(try Data(contentsOf: artifact.weights[0]) == fixture.weights)
        #expect(try Data(contentsOf: #require(artifact.projector)) == fixture.projector)
        let values = try artifact.weights[0].deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        // Persisted with its catalog entry.
        let reopened = try LlamaModelStore(root: fixture.root).artifacts()
        #expect(reopened.first?.catalogEntry == fixture.entry)
        // Every request was a whole file.
        #expect(fixture.server.requests.allSatisfy { $0.range == nil })

        // Already installed.
        #expect(throws: LlamaEngineError.modelExists(model)) { try fixture.downloads.start(fixture.entry) }
    }

    @Test func interruptedTransferResumesWithARange() async throws {
        let fixture = try await Fixture()
        fixture.server.cut("/\(revision)/tiny.gguf", after: 200_000)
        try fixture.downloads.start(fixture.entry)
        try await until { if case .interrupted = state(fixture) { return true } else { return false } }
        guard case .interrupted(.network(let file, _, _))? = state(fixture) else {
            Issue.record("unexpected state \(String(describing: state(fixture)))")
            return
        }
        #expect(file == "tiny.gguf")
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("tiny.gguf.resume").path))
        #expect(fixture.runtime.snapshot()[model] == nil)

        try fixture.downloads.resume(model)
        try await fixture.installed()
        let requests = fixture.server.requests(for: "/\(revision)/tiny.gguf")
        #expect(requests.count == 2)
        #expect(requests.last?.range == "bytes=200000-")
        #expect(requests.last?.ifRange == "\"w1\"")
    }

    @Test func serverWithoutRangesRestartsCleanly() async throws {
        let fixture = try await Fixture()
        fixture.server["/\(revision)/tiny.gguf"] = .init(data: fixture.weights, etag: nil, supportsRanges: false)
        fixture.server.cut("/\(revision)/tiny.gguf", after: 200_000)
        try fixture.downloads.start(fixture.entry)
        try await until { if case .interrupted = state(fixture) { return true } else { return false } }
        // No resume data without validator and ranges: the next try restarts.
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("tiny.gguf.resume").path))

        try fixture.downloads.resume(model)
        try await fixture.installed()
        #expect(fixture.server.requests(for: "/\(revision)/tiny.gguf").map(\.range) == [nil, nil])
    }

    @Test func fileChangedOnTheServerFailsTheDigest() async throws {
        let fixture = try await Fixture()
        let path = "/\(revision)/tiny.gguf"
        fixture.server.cut(path, after: 200_000)
        try fixture.downloads.start(fixture.entry)
        try await until { if case .interrupted = state(fixture) { return true } else { return false } }

        // Same size, other content and entity tag: If-Range no longer
        // matches, the server sends the whole new file.
        fixture.server[path] = .init(data: gguf(fixture.weights.count, seed: 9), etag: "\"w2\"")
        try fixture.downloads.resume(model)
        try await until { if case .failed = state(fixture) { return true } else { return false } }
        guard case .failed(.digestMismatch(let file, let expected, _))? = state(fixture) else {
            Issue.record("unexpected state \(String(describing: state(fixture)))")
            return
        }
        #expect(file == "tiny.gguf" && expected == sha256(fixture.weights))
        #expect(fixture.server.requests(for: path).last?.ifRange == "\"w1\"")
        #expect(fixture.runtime.snapshot()[model] == nil)
        #expect(try LlamaModelStore(root: fixture.root).artifacts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("tiny.gguf").path))

        // The server serves the catalog's file again: a retry restarts it.
        fixture.server[path] = .init(data: fixture.weights, etag: "\"w1\"")
        try fixture.downloads.resume(model)
        try await fixture.installed()
        #expect(fixture.server.requests(for: path).last?.range == nil)
    }

    @Test func partialProjectorNeverMakesTheModelLoadable() async throws {
        let fixture = try await Fixture()
        let projectorPath = "/\(revision)/mmproj.gguf"
        // Late, so that the weights are complete when the download fails.
        fixture.server[projectorPath] = .init(data: fixture.projector, etag: "\"p1\"", status: 404, delay: .milliseconds(500))
        try fixture.downloads.start(fixture.entry)
        try await until { if case .failed = state(fixture) { return true } else { return false } }
        #expect(state(fixture) == .failed(.httpStatus(file: "mmproj.gguf", status: 404)))
        // The weights are verified, yet nothing is in the catalog or the store.
        try await until { fixture.download?.files.first?.status == .verified }
        #expect(fixture.runtime.snapshot()[model] == nil)
        #expect(try LlamaModelStore(root: fixture.root).artifacts().isEmpty)
        await #expect(throws: LlamaEngineError.modelNotFound(model)) {
            try await fixture.runtime.load(model, profile: LlamaLoadProfile(usesProjector: true))
        }

        // A server error is recoverable; the retry only transfers the projector.
        fixture.server[projectorPath] = .init(data: fixture.projector, etag: "\"p1\"", status: 503)
        try fixture.downloads.resume(model)
        try await until { if case .interrupted = state(fixture) { return true } else { return false } }
        fixture.server[projectorPath] = .init(data: fixture.projector, etag: "\"p1\"")
        try fixture.downloads.resume(model)
        try await fixture.installed()
        #expect(fixture.server.requests(for: "/\(revision)/tiny.gguf").count == 1)
        #expect(fixture.runtime.snapshot()[model]?.artifact.projector != nil)
    }

    @Test func resumingKeepsTheOtherTransfersRunning() async throws {
        let fixture = try await Fixture()
        let weightsPath = "/\(revision)/tiny.gguf"
        // The projector fails at once; the weights are still transferring.
        fixture.server.cut("/\(revision)/mmproj.gguf", after: 10_000)
        fixture.server.setThrottle((chunk: 16 << 10, delay: .milliseconds(20)))
        try fixture.downloads.start(fixture.entry)
        try await until { if case .interrupted = state(fixture) { return true } else { return false } }
        #expect(fixture.download?.files.first?.status == .transferring)

        try fixture.downloads.resume(model)
        let before = fixture.download?.files.first?.receivedBytes ?? 0
        // The running transfer keeps reporting under the new token.
        try await until {
            guard let weights = fixture.download?.files.first else { return false }
            return weights.status == .transferring && (weights.receivedBytes ?? 0) > before + 50_000
        }
        try await fixture.installed()
        #expect(fixture.server.requests(for: weightsPath).count == 1)
    }

    @Test func pauseKeepsResumeDataAndResumeContinues() async throws {
        let fixture = try await Fixture()
        fixture.server.setThrottle((chunk: 16 << 10, delay: .milliseconds(20)))
        try fixture.downloads.start(fixture.entry)
        try await until { (fixture.download?.files.first?.receivedBytes ?? 0) > 50_000 }
        try await fixture.downloads.pause(model)
        #expect(state(fixture) == .paused)
        let resumeFile = fixture.directory.appendingPathComponent("tiny.gguf.resume")
        #expect(FileManager.default.fileExists(atPath: resumeFile.path))
        try await Task.sleep(for: .milliseconds(200))
        #expect(state(fixture) == .paused) // no late event changes it

        fixture.server.setThrottle(nil)
        try fixture.downloads.resume(model)
        try await fixture.installed()
        let range = try #require(fixture.server.requests(for: "/\(revision)/tiny.gguf").last?.range)
        #expect(range.hasPrefix("bytes=") && range != "bytes=0-")
    }

    @Test func cancelAbandonsTheDownloadAndItsData() async throws {
        let fixture = try await Fixture()
        fixture.server.setThrottle((chunk: 16 << 10, delay: .milliseconds(20)))
        try fixture.downloads.start(fixture.entry)
        try await until { (fixture.download?.receivedBytes ?? 0) > 0 }
        try await fixture.downloads.cancel(model)
        #expect(fixture.download == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        await #expect(throws: LlamaEngineError.downloadNotFound(model)) { try await fixture.downloads.cancel(model) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.download == nil)
        #expect(fixture.runtime.snapshot()[model] == nil)

        // Starting again is a new download, not disturbed by the old tasks.
        fixture.server.setThrottle(nil)
        try fixture.downloads.start(fixture.entry)
        #expect(throws: LlamaEngineError.downloadExists(model)) { try fixture.downloads.start(fixture.entry) }
        try await fixture.installed()
    }

    @Test func stateSurvivesARelaunch() async throws {
        let fixture = try await Fixture()
        fixture.server.setThrottle((chunk: 16 << 10, delay: .milliseconds(20)))
        try fixture.downloads.start(fixture.entry)
        try await until { (fixture.download?.files.first?.receivedBytes ?? 0) > 50_000 }

        // The process ends during a foreground transfer: the next launch
        // reports it as interrupted, without restarting on its own.
        try await fixture.relaunch()
        guard case .interrupted(.transferLost)? = state(fixture) else {
            Issue.record("unexpected state \(String(describing: state(fixture)))")
            return
        }
        try fixture.downloads.resume(model)
        try await until { (fixture.download?.files.first?.receivedBytes ?? 0) > 50_000 }

        // Paused, then relaunched: the resume data is still used.
        try await fixture.downloads.pause(model)
        try await fixture.relaunch()
        #expect(state(fixture) == .paused)
        fixture.server.setThrottle(nil)
        try fixture.downloads.resume(model)
        try await fixture.installed()
        let last = try #require(fixture.server.requests(for: "/\(revision)/tiny.gguf").last)
        #expect(last.range != nil && last.range != "bytes=0-")
    }

    @Test func receivedFilesAreVerifiedAgainAfterARelaunch() async throws {
        let fixture = try await Fixture()
        fixture.server["/\(revision)/mmproj.gguf"] = .init(data: fixture.projector, etag: "\"p1\"", status: 404,
                                                            delay: .milliseconds(500))
        try fixture.downloads.start(fixture.entry)
        try await until { fixture.download?.files.first?.status == .verified }
        try await until { if case .failed = state(fixture) { return true } else { return false } }

        // A received file altered on disk is checked again at the next launch.
        let weights = fixture.directory.appendingPathComponent("tiny.gguf")
        let handle = try FileHandle(forWritingTo: weights)
        try handle.seek(toOffset: 1000)
        try handle.write(contentsOf: Data([0xFF, 0xFF]))
        try handle.close()
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("record.json"))) as! [String: Any]
        record["received"] = ["tiny.gguf": false]
        try JSONSerialization.data(withJSONObject: record).write(to: fixture.directory.appendingPathComponent("record.json"))

        fixture.server["/\(revision)/mmproj.gguf"] = .init(data: fixture.projector, etag: "\"p1\"")
        try await fixture.relaunch()
        try fixture.downloads.resume(model)
        try await until { if case .failed(.digestMismatch) = state(fixture) { return true } else { return false } }
        try fixture.downloads.resume(model)
        try await fixture.installed()
        #expect(fixture.server.requests(for: "/\(revision)/tiny.gguf").count == 2)
    }

    @Test func unusableResumeDataRestartsCleanly() async throws {
        let fixture = try await Fixture()
        fixture.server.setThrottle((chunk: 16 << 10, delay: .milliseconds(20)))
        try fixture.downloads.start(fixture.entry)
        try await until { (fixture.download?.files.first?.receivedBytes ?? 0) > 50_000 }
        try await fixture.downloads.pause(model)
        try Data("not resume data".utf8).write(to: fixture.directory.appendingPathComponent("tiny.gguf.resume"))

        fixture.server.setThrottle(nil)
        try fixture.downloads.resume(model)
        try await fixture.installed()
        let requests = fixture.server.requests(for: "/\(revision)/tiny.gguf")
        #expect(requests.last?.range == nil)
    }

    @Test func insufficientSpaceIsRefusedBeforeAnyTransfer() async throws {
        let fixture = try await Fixture(capacity: 1_000_000)
        #expect(throws: LlamaEngineError.self) { try fixture.downloads.start(fixture.entry) }
        do {
            try fixture.downloads.start(fixture.entry)
        } catch LlamaEngineError.insufficientSpace(let required, let available) {
            #expect(required > available)
        }
        #expect(fixture.download == nil)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func observationReportsTheStates() async throws {
        let fixture = try await Fixture()
        fixture.server.setThrottle((chunk: 32 << 10, delay: .milliseconds(10)))
        let observer = Task { [downloads = fixture.downloads] in
            var states: [String] = []
            for await update in downloads.updates(bufferLimit: 1000) {
                guard let download = update.snapshot[model] else {
                    if !states.isEmpty { break }
                    continue
                }
                let name = switch download.state {
                case .downloading: "downloading"
                case .verifying: "verifying"
                case .installing: "installing"
                default: "other"
                }
                if states.last != name { states.append(name) }
            }
            return states
        }
        try await Task.sleep(for: .milliseconds(50))
        try fixture.downloads.start(fixture.entry)
        try await fixture.installed()
        let states = await observer.value
        #expect(states.first == "downloading")
        #expect(states.last == "installing")
        #expect(!states.contains("other"))
    }

    /// The production configuration: a background session, run by the
    /// system daemon. The system accepts it only from an application whose
    /// bundle and signing identifiers match: the `xctest` tool running the
    /// package tests is refused (its transfers stall), so this test runs only
    /// in an application host. Reattachment after a relaunch needs a new
    /// process; it is checked on a device with the demo application.
    @Test(.enabled(if: Bundle.main.bundleURL.pathExtension == "app", "background sessions need an application host"))
    func backgroundSessionDownloads() async throws {
        let fixture = try await Fixture()
        let identifier = "org.ggml.llama.tests.\(UUID().uuidString)"
        fixture.downloads.invalidate()
        fixture.downloads = try LlamaModelDownloads(runtime: fixture.runtime,
                                                    configuration: .init(sessionIdentifier: identifier))
        await fixture.downloads.reattached()
        #expect(fixture.downloads.sessionIdentifier == identifier)
        try fixture.downloads.start(fixture.entry)
        try await fixture.installed()
    }

    /// The shipped catalog entry from its real server (Hugging Face and its
    /// CDN, behind a redirection): pause, resume with a byte range, digests,
    /// installation. Opt-in (about 2 GB): LLAMA_DOWNLOAD_REAL_CATALOG=1
    /// (TEST_RUNNER_LLAMA_DOWNLOAD_REAL_CATALOG=1 through xcodebuild).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LLAMA_DOWNLOAD_REAL_CATALOG"] == "1"),
          .timeLimit(.minutes(60)))
    func realCatalogEntryDownloadsAndInstalls() async throws {
        let catalog = try LlamaModelCatalog.decode(Data(contentsOf: catalogFile))
        let entry = try #require(catalog.models.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try LlamaRuntime(store: LlamaModelStore(root: root))
        let downloads = try LlamaModelDownloads(runtime: runtime, sessionConfiguration: .ephemeral)
        defer { downloads.invalidate() }
        await downloads.reattached()

        func received() -> Int64 { downloads.snapshot()[entry.id]?.receivedBytes ?? 0 }
        let clock = ContinuousClock()
        let started = clock.now
        try downloads.start(entry)
        while received() < 50_000_000 { try await Task.sleep(for: .milliseconds(200)) }
        try await downloads.pause(entry.id)
        #expect(downloads.snapshot()[entry.id]?.state == .paused)
        let resumeFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("downloads/\(entry.id)").path)
            .filter { $0.hasSuffix(".resume") }
        print("real download: paused after \(received()) bytes, resume data for \(resumeFiles)")
        #expect(!resumeFiles.isEmpty)

        // A transfer that restarted instead of resuming reports offset 0.
        func weights() -> Int64 { downloads.snapshot()[entry.id]?.files.first?.receivedBytes ?? 0 }
        let paused = weights()
        try downloads.resume(entry.id)
        var lowest = paused
        while weights() <= paused + 10_000_000 {
            lowest = min(lowest, weights())
            try await Task.sleep(for: .milliseconds(20))
        }
        print("real download: weights paused at \(paused) bytes, lowest after resume \(lowest)")
        #expect(paused > 0 && lowest >= paused)
        while runtime.snapshot()[entry.id] == nil {
            if case .failed(let issue) = downloads.snapshot()[entry.id]?.state {
                Issue.record("failed: \(issue)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        let artifact = try #require(runtime.snapshot()[entry.id]?.artifact)
        #expect(artifact.catalogEntry == entry)
        #expect(artifact.projector?.lastPathComponent == entry.projector?.name)
        print("real download: installed \(entry.totalSize) bytes in \(clock.now - started)")
    }
}
