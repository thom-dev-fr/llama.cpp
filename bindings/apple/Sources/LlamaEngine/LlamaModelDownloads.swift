import CryptoKit
import Foundation

/// Why a download stopped.
public enum LlamaDownloadIssue: Hashable, Sendable, Codable {
    /// A transfer error (`URLError` code).
    case network(file: String, code: Int, message: String)
    /// The server answered with an HTTP error.
    case httpStatus(file: String, status: Int)
    /// The transferred file does not have the size of the catalog.
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    /// The transferred file does not have the SHA-256 of the catalog: the file
    /// changed on the server, or the transfer is corrupt.
    case digestMismatch(file: String, expected: String, actual: String)
    case insufficientSpace(required: Int64, available: Int64)
    /// The transfer ended without the application: the system cancelled it,
    /// or the application was terminated (a foreground session's transfers
    /// end with the process).
    case transferLost(file: String, reason: String)
    /// A local file operation or the installation failed.
    case storage(String)
}

/// One model being downloaded. It leaves the downloads once installed: the
/// model is then in the runtime catalog.
public struct LlamaModelDownload: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Transfers are running or waiting for the system to run them.
        case downloading
        /// Paused by the application; `resume` continues from the data kept.
        case paused
        /// Stopped by a recoverable cause (network, server unavailable, the
        /// application ended); `resume` continues where possible, or
        /// restarts the file.
        case interrupted(LlamaDownloadIssue)
        /// Every file is transferred; sizes and digests are being checked.
        case verifying
        /// The verified files are moving into the model store.
        case installing
        /// Stopped by a cause that resuming would not fix as is (HTTP error,
        /// digest mismatch, no space...). `resume` restarts the failed file
        /// from the beginning.
        case failed(LlamaDownloadIssue)
    }

    public enum FileStatus: String, Hashable, Sendable, Codable {
        case pending, transferring, received, verified
    }

    public struct File: Hashable, Sendable {
        public var name: String
        public var isProjector: Bool
        public var size: Int64
        /// Bytes on disk or transferred so far; nil when unknown (a paused
        /// transfer keeps its data in the resume data).
        public var receivedBytes: Int64?
        public var status: FileStatus
    }

    public var entry: LlamaModelCatalog.Entry
    public var state: State
    public var files: [File]

    public var id: LlamaModelID { entry.id }
    public var totalBytes: Int64 { entry.totalSize }
    public var receivedBytes: Int64 { files.reduce(0) { $0 + ($1.receivedBytes ?? 0) } }
    public var fractionCompleted: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
}

public struct LlamaDownloadsSnapshot: Hashable, Sendable {
    /// Sorted by model identifier.
    public var downloads: [LlamaModelDownload]

    public subscript(id: LlamaModelID) -> LlamaModelDownload? {
        downloads.first { $0.id == id }
    }
}

public typealias LlamaDownloadsUpdates = LlamaStateUpdates<LlamaDownloadsSnapshot>

/// Downloads catalog models with `URLSession` (ADR 0003), then installs them
/// in the runtime's model store.
///
/// - A model becomes loadable only once every file (weights, shards,
///   projector) is transferred, has the catalog's size and SHA-256, and the
///   whole set is installed in one rename. A partial projector never gives a
///   model vision; files in transfer stay in `<store>/downloads`.
/// - The state of each download is persisted (`downloads/<id>/record.json`,
///   resume data next to it). Each transfer task carries its identity in
///   `taskDescription`; a new instance with the same session identifier
///   reattaches the tasks the system kept and resumes the verifications.
/// - `pause` keeps resume data when the server allows it; `resume` continues
///   from it, or restarts the file cleanly when there is none or it is
///   unusable. `cancel` abandons the download and deletes its data.
///
/// Create one instance per session identifier, at launch, and keep it for the
/// life of the application: the session keeps it alive until `invalidate`.
///
/// iOS application lifecycle: with a background session, the system may
/// relaunch the application in the background to deliver the session's
/// events. Recreate this object with the same identifier at launch, and
/// forward the events:
///
/// ```swift
/// // SwiftUI
/// .backgroundTask(.urlSession(LlamaModelDownloads.defaultSessionIdentifier)) {
///     await downloads.backgroundEventsFinished()
/// }
/// // UIApplicationDelegate
/// func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
///                  completionHandler: @escaping () -> Void) {
///     _ = downloads.handleBackgroundEvents(forSession: identifier, completionHandler: completionHandler)
/// }
/// ```
///
/// The system continues background transfers while the application is
/// suspended or terminated by the system; it cancels them when the user force
/// quits the application. They then appear `interrupted` at the next launch.
public final class LlamaModelDownloads: Sendable {
    public static let defaultSessionIdentifier = "org.ggml.llama.model-downloads"

    public struct Configuration: Sendable {
        /// Identifier of a background session; nil uses a foreground session,
        /// whose transfers end with the process.
        public var sessionIdentifier: String?
        public var allowsCellularAccess: Bool
        /// Lets the system delay transfers to better conditions.
        public var isDiscretionary: Bool
        /// App group container, for a session shared with an extension.
        public var sharedContainerIdentifier: String?
        public var observationBufferLimit: Int

        public init(sessionIdentifier: String? = LlamaModelDownloads.defaultSessionIdentifier,
                    allowsCellularAccess: Bool = true, isDiscretionary: Bool = false,
                    sharedContainerIdentifier: String? = nil, observationBufferLimit: Int = 64) {
            self.sessionIdentifier = sessionIdentifier
            self.allowsCellularAccess = allowsCellularAccess
            self.isDiscretionary = isDiscretionary
            self.sharedContainerIdentifier = sharedContainerIdentifier
            self.observationBufferLimit = observationBufferLimit
        }

        var sessionConfiguration: URLSessionConfiguration {
            let configuration: URLSessionConfiguration
            if let sessionIdentifier {
                configuration = .background(withIdentifier: sessionIdentifier)
                configuration.sessionSendsLaunchEvents = true
                configuration.isDiscretionary = isDiscretionary
                configuration.sharedContainerIdentifier = sharedContainerIdentifier
            } else {
                configuration = .default
            }
            configuration.allowsCellularAccess = allowsCellularAccess
            return configuration
        }
    }

    private let coordinator: DownloadCoordinator

    /// Reattaches the downloads of a previous launch. The runtime needs a model store.
    public convenience init(runtime: LlamaRuntime, configuration: Configuration = Configuration()) throws {
        try self.init(runtime: runtime, sessionConfiguration: configuration.sessionConfiguration,
                      observationBufferLimit: configuration.observationBufferLimit)
    }

    package init(runtime: LlamaRuntime, sessionConfiguration: URLSessionConfiguration, observationBufferLimit: Int = 64) throws {
        guard let store = runtime.store else {
            throw LlamaEngineError.invalidConfiguration("downloads need a runtime with a model store")
        }
        coordinator = try DownloadCoordinator(runtime: runtime, store: store, configuration: sessionConfiguration,
                                              bufferLimit: observationBufferLimit)
    }

    public var sessionIdentifier: String? { coordinator.session.configuration.identifier }

    public func snapshot() -> LlamaDownloadsSnapshot {
        coordinator.snapshot()
    }

    /// The current snapshot, then every change; a subscriber that falls
    /// behind receives one `resync`.
    public func updates(bufferLimit: Int? = nil) -> LlamaDownloadsUpdates {
        coordinator.hub.subscribe(limit: bufferLimit ?? coordinator.bufferLimit) { coordinator.snapshot() }
    }

    /// Starts downloading a catalog model. Fails if the model is already in
    /// the runtime, already downloading, or if the volume lacks the space.
    public func start(_ entry: LlamaModelCatalog.Entry) throws {
        try coordinator.start(entry)
    }

    /// Pauses the transfers and keeps their resume data.
    public func pause(_ id: LlamaModelID) async throws {
        try await coordinator.pause(id)
    }

    /// Continues a paused, interrupted or failed download.
    public func resume(_ id: LlamaModelID) throws {
        try coordinator.resume(id)
    }

    /// Abandons a download: its transfers stop and its data is deleted.
    /// Refused (`downloadInstalling`) once its verified files are moving into
    /// the store: the model then appears in the catalog and can be removed.
    public func cancel(_ id: LlamaModelID) async throws {
        try await coordinator.cancel(id)
    }

    /// Forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
    /// false when the identifier is not this session's.
    public func handleBackgroundEvents(forSession identifier: String,
                                       completionHandler: @escaping @Sendable () -> Void) -> Bool {
        coordinator.handleBackgroundEvents(identifier, completionHandler)
    }

    /// Returns once the session delivered the events of a background launch
    /// (SwiftUI `.backgroundTask(.urlSession(_:))`).
    public func backgroundEventsFinished() async {
        await coordinator.backgroundEventsFinished()
    }

    /// Ends the session. Tasks of a background session continue in the
    /// system; a new instance reattaches them.
    public func invalidate() {
        coordinator.session.finishTasksAndInvalidate()
    }

    /// Returns once the tasks of a previous launch are reattached.
    package func reattached() async {
        await coordinator.reattachment.value
    }

    package var session: URLSession { coordinator.session }
}

// MARK: - Coordinator

/// Identity of a transfer task, in its `taskDescription`.
struct TransferIdentity: Codable, Hashable {
    var model: LlamaModelID
    var file: String
    /// The download's current token: tasks of an older token (paused,
    /// restarted, abandoned) only deliver files.
    var token: UUID
    /// Started from resume data.
    var resumed: Bool

    init(model: LlamaModelID, file: String, token: UUID, resumed: Bool) {
        self.model = model
        self.file = file
        self.token = token
        self.resumed = resumed
    }

    init?(_ task: URLSessionTask) {
        guard let description = task.taskDescription, let data = description.data(using: .utf8),
              let identity = try? JSONDecoder().decode(TransferIdentity.self, from: data) else {
            return nil
        }
        self = identity
    }

    var encoded: String {
        String(decoding: try! JSONEncoder().encode(self), as: UTF8.self)
    }
}

/// The persisted part of a download.
struct DownloadRecord: Codable {
    enum Phase: Codable, Hashable {
        case running, paused
        case interrupted(LlamaDownloadIssue)
        case failed(LlamaDownloadIssue)
    }

    var version = 1
    var entry: LlamaModelCatalog.Entry
    var token: UUID
    var phase: Phase
    /// Files moved into the download directory, and whether their size and
    /// digest were checked.
    var received: [String: Bool]
}

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// A download: its record and the live state of its transfers.
    private final class Transfer: @unchecked Sendable { // guarded by the coordinator's lock
        var record: DownloadRecord
        let directory: URL
        var tasks: [String: URLSessionDownloadTask] = [:]
        var written: [String: Int64] = [:]
        var verifying: Set<String> = []
        var installing = false
        var lastProgress = ContinuousClock.now

        init(record: DownloadRecord, directory: URL) {
            self.record = record
            self.directory = directory
        }
    }

    private enum Outcome {
        case received
        case http(Int)
        case storage(String)
    }

    let runtime: LlamaRuntime
    let store: LlamaModelStore
    let hub = UpdateHub<LlamaDownloadsSnapshot>()
    let bufferLimit: Int
    private(set) var session: URLSession!
    private(set) var reattachment: Task<Void, Never>!
    private let verification = DispatchQueue(label: "org.ggml.llama.downloads.verify", qos: .utility)

    private let lock = NSLock()
    // guarded by lock
    private var transfers: [LlamaModelID: Transfer] = [:]
    private var outcomes: [Int: Outcome] = [:] // by task identifier
    private var backgroundCompletion: (@Sendable () -> Void)?
    private var eventsFinished = false
    private var eventWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtime: LlamaRuntime, store: LlamaModelStore, configuration: URLSessionConfiguration, bufferLimit: Int) throws {
        self.runtime = runtime
        self.store = store
        self.bufferLimit = bufferLimit
        super.init()
        try loadRecords()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "org.ggml.llama.downloads"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        reattachment = Task { [self] in await reattach() }
    }

    private var root: URL { store.downloadsDirectory }

    private func directory(of id: LlamaModelID) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    // MARK: Snapshots

    func snapshot() -> LlamaDownloadsSnapshot {
        lock.withLock {
            LlamaDownloadsSnapshot(downloads: transfers.values.map(describe).sorted { $0.id < $1.id })
        }
    }

    private func describe(_ transfer: Transfer) -> LlamaModelDownload { // lock held
        let entry = transfer.record.entry
        let files = entry.files.map { file -> LlamaModelDownload.File in
            let status: LlamaModelDownload.FileStatus
            let received: Int64?
            switch transfer.record.received[file.name] {
            case true?: (status, received) = (.verified, file.size)
            case false?: (status, received) = (.received, file.size)
            case nil where transfer.tasks[file.name] != nil: (status, received) = (.transferring, transfer.written[file.name] ?? 0)
            case nil: (status, received) = (.pending, transfer.written[file.name])
            }
            return LlamaModelDownload.File(name: file.name, isProjector: file == entry.projector, size: file.size,
                                           receivedBytes: received, status: status)
        }
        let state: LlamaModelDownload.State
        if transfer.installing {
            state = .installing
        } else {
            switch transfer.record.phase {
            case .failed(let issue): state = .failed(issue)
            case .interrupted(let issue): state = .interrupted(issue)
            case .paused: state = .paused
            case .running:
                state = transfer.tasks.isEmpty && !transfer.verifying.isEmpty ? .verifying : .downloading
            }
        }
        return LlamaModelDownload(entry: entry, state: state, files: files)
    }

    private func publish() {
        hub.publish { snapshot() }
    }

    // MARK: Records

    private func save(_ transfer: Transfer) throws { // lock held
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transfer.record).write(to: transfer.directory.appendingPathComponent("record.json"), options: .atomic)
    }

    private func persist(_ transfer: Transfer) { // lock held
        do {
            try save(transfer)
        } catch {
            transfer.record.phase = .failed(.storage("cannot save the download state: \(error.localizedDescription)"))
        }
    }

    /// Records of a previous launch. A received file counts even if the
    /// record missed it (it is only ever renamed into place complete); it is
    /// verified again.
    private func loadRecords() throws {
        let manager = FileManager.default
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("record.json")),
                  var record = try? JSONDecoder().decode(DownloadRecord.self, from: data),
                  record.entry.id.rawValue == directory.lastPathComponent,
                  (try? record.entry.validate()) != nil,
                  !store.contains(record.entry.id) else {
                // Unreadable, or installed before the record was removed.
                try? manager.removeItem(at: directory)
                continue
            }
            for file in record.entry.files {
                let exists = manager.fileExists(atPath: directory.appendingPathComponent(file.name).path)
                if !exists {
                    record.received[file.name] = nil
                } else if record.received[file.name] != true {
                    record.received[file.name] = false
                }
            }
            transfers[record.entry.id] = Transfer(record: record, directory: directory)
        }
    }

    /// Reattaches the tasks the system kept, cancels unknown or outdated
    /// ones, then reports transfers that did not survive and resumes the
    /// verifications.
    private func reattach() async {
        let tasks = await session.allTasks
        var stale: [URLSessionTask] = []
        lock.withLock {
            for task in tasks {
                if let identity = TransferIdentity(task), transfers[identity.model]?.tasks[identity.file] === task {
                    continue // started by this instance meanwhile
                }
                guard let download = task as? URLSessionDownloadTask, let identity = TransferIdentity(task),
                      let transfer = transfers[identity.model], transfer.record.token == identity.token,
                      transfer.record.phase == .running, transfer.record.received[identity.file] == nil,
                      transfer.tasks[identity.file] == nil else {
                    stale.append(task)
                    continue
                }
                transfer.tasks[identity.file] = download
                transfer.written[identity.file] = download.countOfBytesReceived
            }
            for transfer in transfers.values where transfer.record.phase == .running {
                let lost = transfer.record.entry.files.first {
                    transfer.record.received[$0.name] == nil && transfer.tasks[$0.name] == nil
                }
                if let lost {
                    transfer.record.phase = .interrupted(.transferLost(
                        file: lost.name, reason: "the transfer did not continue after the application ended"))
                    persist(transfer)
                }
            }
            for transfer in transfers.values {
                verifyReceived(transfer)
            }
        }
        stale.forEach { $0.cancel() }
        publish()
    }

    // MARK: Commands

    func start(_ entry: LlamaModelCatalog.Entry) throws {
        try entry.validate()
        guard runtime.snapshot()[entry.id] == nil, !store.contains(entry.id) else {
            throw LlamaEngineError.modelExists(entry.id)
        }
        try lock.withLock {
            guard transfers[entry.id] == nil else { throw LlamaEngineError.downloadExists(entry.id) }
            try store.checkSpace(for: entry.totalSize)
            let directory = directory(of: entry.id)
            let manager = FileManager.default
            try? manager.removeItem(at: directory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let transfer = Transfer(record: DownloadRecord(entry: entry, token: UUID(), phase: .running, received: [:]),
                                    directory: directory)
            do {
                try save(transfer)
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
            transfers[entry.id] = transfer
            launch(transfer)
        }
        publish()
    }

    func pause(_ id: LlamaModelID) async throws {
        let (tasks, transfer): ([String: URLSessionDownloadTask], Transfer) = try lock.withLock {
            guard let transfer = transfers[id] else { throw LlamaEngineError.downloadNotFound(id) }
            switch transfer.record.phase {
            case .running, .interrupted: break // an interrupted download may still transfer other files
            case .paused, .failed: return ([:], transfer)
            }
            transfer.record.phase = .paused
            transfer.record.token = UUID()
            defer { transfer.tasks.removeAll() }
            persist(transfer)
            return (transfer.tasks, transfer)
        }
        publish()
        await withTaskGroup(of: Void.self) { group in
            for (file, task) in tasks {
                group.addTask { [self] in
                    let data = await task.cancelByProducingResumeData()
                    lock.withLock { saveResumeData(data, file: file, of: transfer) }
                }
            }
        }
        publish()
    }

    func resume(_ id: LlamaModelID) throws {
        try lock.withLock {
            guard let transfer = transfers[id] else { throw LlamaEngineError.downloadNotFound(id) }
            switch transfer.record.phase {
            case .running:
                return
            case .paused, .interrupted, .failed:
                let missing = transfer.record.entry.files.filter { transfer.record.received[$0.name] == nil }
                try store.checkSpace(for: missing.reduce(0) { $0 + $1.size - (transfer.written[$1.name] ?? 0) })
                transfer.record.phase = .running
                transfer.record.token = UUID()
                // Transfers still running (an interrupted download) keep
                // reporting under the new token.
                for (file, task) in transfer.tasks {
                    task.taskDescription = TransferIdentity(model: id, file: file, token: transfer.record.token,
                                                            resumed: TransferIdentity(task)?.resumed ?? false).encoded
                }
                persist(transfer)
                launch(transfer)
                verifyReceived(transfer)
            }
        }
        publish()
    }

    func cancel(_ id: LlamaModelID) async throws {
        let (directory, tasks): (URL, [URLSessionDownloadTask]) = try lock.withLock {
            guard let transfer = transfers[id] else { throw LlamaEngineError.downloadNotFound(id) }
            guard !transfer.installing else { throw LlamaEngineError.downloadInstalling(id) }
            transfers[id] = nil
            defer { transfer.tasks.removeAll() }
            return (transfer.directory, Array(transfer.tasks.values))
        }
        publish()
        tasks.forEach { $0.cancel() }
        // Late events find no download; tasks of the reattachment are matched
        // by token, which nothing holds any more.
        try? await runtime.native.workers.run { try FileManager.default.removeItem(at: directory) }
    }

    func handleBackgroundEvents(_ identifier: String, _ completion: @escaping @Sendable () -> Void) -> Bool {
        guard identifier == session.configuration.identifier else { return false }
        let finished: Bool = lock.withLock {
            // The session may have delivered the batch before the call.
            if eventsFinished {
                eventsFinished = false
                return true
            }
            backgroundCompletion = completion
            return false
        }
        if finished { DispatchQueue.main.async(execute: completion) }
        return true
    }

    func backgroundEventsFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished: Bool = lock.withLock {
                if eventsFinished {
                    eventsFinished = false
                    return true
                }
                eventWaiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }

    // MARK: Transfers

    /// Starts a task for every file neither received nor transferring: from
    /// its resume data when there is some, from the beginning otherwise.
    private func launch(_ transfer: Transfer) { // lock held
        for file in transfer.record.entry.files where transfer.record.received[file.name] == nil && transfer.tasks[file.name] == nil {
            launch(file, of: transfer)
        }
    }

    private func launch(_ file: LlamaModelCatalog.File, of transfer: Transfer, ignoringResumeData: Bool = false) { // lock held
        let resumeURL = transfer.directory.appendingPathComponent(file.name + ".resume")
        let resumeData = ignoringResumeData ? nil : try? Data(contentsOf: resumeURL)
        if ignoringResumeData {
            try? FileManager.default.removeItem(at: resumeURL)
        }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: file.url)
        task.taskDescription = TransferIdentity(model: transfer.record.entry.id, file: file.name,
                                                token: transfer.record.token, resumed: resumeData != nil).encoded
        task.countOfBytesClientExpectsToReceive = file.size
        transfer.tasks[file.name] = task
        if resumeData == nil {
            transfer.written[file.name] = 0
        }
        task.resume()
    }

    private func saveResumeData(_ data: Data?, file: String, of transfer: Transfer) { // lock held
        let url = transfer.directory.appendingPathComponent(file + ".resume")
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            // Without new data, older data names a temporary file the
            // system no longer keeps: the next start is from the beginning.
            try? FileManager.default.removeItem(at: url)
            transfer.written[file] = nil
        }
    }

    /// Stops the other transfers of a download that failed, keeping their
    /// resume data so that a retry only restarts the failed file.
    private func stopTransfers(of transfer: Transfer) { // lock held
        let tasks = transfer.tasks
        transfer.tasks.removeAll()
        // Their cancellation is expected: it must not replace the failure.
        transfer.record.token = UUID()
        for (file, task) in tasks {
            task.cancel(byProducingResumeData: { [self] data in
                lock.withLock { saveResumeData(data, file: file, of: transfer) }
            })
        }
    }

    private func current(_ identity: TransferIdentity) -> Transfer? { // lock held
        guard let transfer = transfers[identity.model], transfer.record.token == identity.token else { return nil }
        return transfer
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let identity = TransferIdentity(downloadTask) else { return }
        let changed: Bool = lock.withLock {
            guard let transfer = current(identity) else { return false }
            transfer.written[identity.file] = totalBytesWritten
            let now = ContinuousClock.now
            guard now - transfer.lastProgress >= .milliseconds(100) || totalBytesWritten == totalBytesExpectedToWrite else {
                return false
            }
            transfer.lastProgress = now
            return true
        }
        if changed { publish() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        guard let identity = TransferIdentity(downloadTask) else { return }
        lock.withLock { current(identity)?.written[identity.file] = fileOffset }
        publish()
    }

    /// The file must leave `location` before returning. A completed file is
    /// kept even from an outdated task (paused just as it finished), unless
    /// the download was abandoned.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = TransferIdentity(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock {
            guard let transfer = transfers[identity.model], transfer.record.received[identity.file] == nil else { return }
            guard (200..<300).contains(status) else {
                outcomes[downloadTask.taskIdentifier] = .http(status)
                return
            }
            let target = transfer.directory.appendingPathComponent(identity.file)
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                transfer.record.received[identity.file] = false
                persist(transfer)
                outcomes[downloadTask.taskIdentifier] = .received
            } catch {
                outcomes[downloadTask.taskIdentifier] = .storage("cannot keep \(identity.file): \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identity = TransferIdentity(task) else { return }
        lock.withLock {
            let outcome = outcomes.removeValue(forKey: task.taskIdentifier)
            guard let transfer = transfers[identity.model] else { return }
            if transfer.tasks[identity.file] === task {
                transfer.tasks[identity.file] = nil
            }
            let resumeURL = transfer.directory.appendingPathComponent(identity.file + ".resume")
            if case .received? = outcome {
                try? FileManager.default.removeItem(at: resumeURL)
                verifyReceived(transfer)
                return
            }
            // Errors of outdated tasks (pause, cancel, retry) are expected.
            guard transfer.record.token == identity.token else { return }
            let issue: LlamaDownloadIssue
            var recoverable = false
            switch outcome {
            case .http(let status)?:
                try? FileManager.default.removeItem(at: resumeURL)
                transfer.written[identity.file] = nil
                issue = .httpStatus(file: identity.file, status: status)
                recoverable = status >= 500 || status == 408 || status == 429
            case .storage(let reason)?:
                issue = .storage(reason)
            case .received?, nil:
                guard let error = error as? URLError else {
                    issue = .storage(error.map { "\($0)" } ?? "the transfer ended without a file")
                    break
                }
                let resumeData = error.downloadTaskResumeData
                if identity.resumed && resumeData == nil && !Self.isConnectivity(error.code) {
                    // Unusable resume data: restart the file cleanly, once.
                    if let file = transfer.record.entry.files.first(where: { $0.name == identity.file }) {
                        launch(file, of: transfer, ignoringResumeData: true)
                    }
                    return
                }
                saveResumeData(resumeData, file: identity.file, of: transfer)
                if error.code == .cancelled {
                    let reason = (error as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
                    issue = .transferLost(file: identity.file, reason: Self.describeCancellation(reason))
                    recoverable = true
                } else {
                    issue = .network(file: identity.file, code: error.errorCode, message: error.localizedDescription)
                    recoverable = !Self.isFatal(error.code)
                }
            }
            if recoverable {
                transfer.record.phase = .interrupted(issue)
            } else {
                transfer.record.phase = .failed(issue)
                stopTransfers(of: transfer)
            }
            persist(transfer)
        }
        publish()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let (completion, waiters): ((@Sendable () -> Void)?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            // Kept for a handler that arrives after the batch.
            eventsFinished = backgroundCompletion == nil && eventWaiters.isEmpty
            defer {
                backgroundCompletion = nil
                eventWaiters.removeAll()
            }
            return (backgroundCompletion, eventWaiters)
        }
        if let completion { DispatchQueue.main.async(execute: completion) }
        waiters.forEach { $0.resume() }
    }

    // MARK: Verification and installation

    /// Verifies the received files not yet checked, on a utility queue (never
    /// the cooperative pool); installs once every file is verified.
    private func verifyReceived(_ transfer: Transfer) { // lock held
        if case .failed = transfer.record.phase { return }
        for file in transfer.record.entry.files where transfer.record.received[file.name] == false && !transfer.verifying.contains(file.name) {
            transfer.verifying.insert(file.name)
            let url = transfer.directory.appendingPathComponent(file.name)
            verification.async { [self] in
                let issue = Self.verify(url, file)
                lock.withLock { verified(file, issue: issue, of: transfer) }
                publish()
            }
        }
        installIfComplete(transfer)
    }

    private func verified(_ file: LlamaModelCatalog.File, issue: LlamaDownloadIssue?, of transfer: Transfer) { // lock held
        transfer.verifying.remove(file.name)
        guard transfers[transfer.record.entry.id] === transfer, transfer.record.received[file.name] == false else { return }
        if let issue {
            try? FileManager.default.removeItem(at: transfer.directory.appendingPathComponent(file.name))
            transfer.record.received[file.name] = nil
            transfer.written[file.name] = nil
            transfer.record.phase = .failed(issue)
            stopTransfers(of: transfer)
        } else {
            transfer.record.received[file.name] = true
        }
        persist(transfer)
        installIfComplete(transfer)
    }

    private func installIfComplete(_ transfer: Transfer) { // lock held
        let entry = transfer.record.entry
        guard !transfer.installing, entry.files.allSatisfy({ transfer.record.received[$0.name] == true }) else { return }
        transfer.installing = true
        Task { [self] in
            do {
                _ = try await runtime.installDownload(entry, from: transfer.directory)
                lock.withLock {
                    if transfers[entry.id] === transfer {
                        transfers[entry.id] = nil
                    }
                }
                try? await runtime.native.workers.run { try FileManager.default.removeItem(at: transfer.directory) }
            } catch {
                lock.withLock {
                    transfer.installing = false
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    transfer.record.phase = .failed(.storage("installation failed: \(reason)"))
                    persist(transfer)
                }
            }
            publish()
        }
    }

    /// Size, then SHA-256 of the whole file.
    static func verify(_ url: URL, _ file: LlamaModelCatalog.File) -> LlamaDownloadIssue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .storage("cannot read \(file.name)")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int64.init) ?? -1
        guard size == file.size else {
            return .sizeMismatch(file: file.name, expected: file.size, actual: size)
        }
        do {
            try handle.seek(toOffset: 0)
            var hash = SHA256()
            while true {
                let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return digest == file.sha256 ? nil : .digestMismatch(file: file.name, expected: file.sha256, actual: digest)
        } catch {
            return .storage("cannot read \(file.name): \(error.localizedDescription)")
        }
    }

    static func isConnectivity(_ code: URLError.Code) -> Bool {
        [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
         .backgroundSessionWasDisconnected].contains(code)
    }

    /// Errors that resuming as is would not fix.
    static func isFatal(_ code: URLError.Code) -> Bool {
        [.badURL, .unsupportedURL, .cannotCreateFile, .cannotWriteToFile, .cannotMoveFile, .fileDoesNotExist,
         .noPermissionsToReadFile, .dataLengthExceedsMaximum, .userAuthenticationRequired, .userCancelledAuthentication,
         .appTransportSecurityRequiresSecureConnection, .fileIsDirectory].contains(code)
    }

    static func describeCancellation(_ reason: Int?) -> String {
        switch reason {
        case NSURLErrorCancelledReasonUserForceQuitApplication?: return "the user force quit the application"
        case NSURLErrorCancelledReasonBackgroundUpdatesDisabled?: return "background app refresh is disabled"
        case NSURLErrorCancelledReasonInsufficientSystemResources?: return "the system lacked resources"
        default: return "the system cancelled the transfer"
        }
    }
}
