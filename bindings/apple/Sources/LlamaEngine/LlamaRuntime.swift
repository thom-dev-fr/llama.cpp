import Foundation

/// Runtime shared by the sessions of an application (ADR 0002).
///
/// Created explicitly by the application; there is no hidden singleton. It
/// owns one native engine in catalog mode, the model catalog (managed models
/// of an optional `LlamaModelStore` and registered files) and the admission
/// queue of generations. Conversations stay with the callers.
///
/// - A loaded instance is an artifact with a `LlamaLoadProfile`: requests with
///   the same model and profile share its weights; different profiles get
///   distinct instances and never share resources.
/// - Admission is the runtime's: at most `maximumActiveGenerations` run, at
///   most `maximumWaitingRequests` wait (first come, first served), more fail
///   with `queueFull`. Each instance has as many engine slots as generations
///   may run, so the engine never queues an admitted generation for a slot.
/// - An explicit unload closes the model's admissions, ends its generations
///   and waiting requests, and returns once the engine freed its resources.
public final class LlamaRuntime: Sendable {
    public struct Limits: Hashable, Sendable {
        /// Instances resident at the same time (loading and unloading
        /// included); idle ones are evicted, least recently used first.
        public var maximumResidentModels: Int
        /// Generations running at the same time.
        public var maximumActiveGenerations: Int
        /// Requests waiting for admission; beyond that, submission fails.
        public var maximumWaitingRequests: Int
        /// Longest wait for admission; nil waits until cancelled.
        public var admissionTimeout: Duration?

        public init(maximumResidentModels: Int = 1, maximumActiveGenerations: Int = 1, maximumWaitingRequests: Int = 4,
                    admissionTimeout: Duration? = .seconds(300)) {
            self.maximumResidentModels = maximumResidentModels
            self.maximumActiveGenerations = maximumActiveGenerations
            self.maximumWaitingRequests = maximumWaitingRequests
            self.admissionTimeout = admissionTimeout
        }
    }

    public struct Configuration: Hashable, Sendable {
        public var limits: Limits
        /// Longest wait of an admitted request or explicit load for its
        /// instance to be resident (eviction and loading included).
        public var loadTimeout: Duration
        /// Native events queued per request before it fails with queue_full.
        public var maximumEventsPerRequest: Int
        /// Updates queued per subscriber before they collapse into a resync.
        public var observationBufferLimit: Int

        public init(limits: Limits = Limits(), loadTimeout: Duration = .seconds(300),
                    maximumEventsPerRequest: Int = 256, observationBufferLimit: Int = 64) {
            self.limits = limits
            self.loadTimeout = loadTimeout
            self.maximumEventsPerRequest = maximumEventsPerRequest
            self.observationBufferLimit = observationBufferLimit
        }

        func validate() throws {
            func require(_ condition: Bool, _ reason: String) throws {
                if !condition { throw LlamaEngineError.invalidConfiguration(reason) }
            }
            try require(limits.maximumResidentModels >= 1, "maximumResidentModels must be at least 1")
            try require(limits.maximumActiveGenerations >= 1, "maximumActiveGenerations must be at least 1")
            try require(limits.maximumWaitingRequests >= 0, "maximumWaitingRequests must not be negative")
            try require(limits.admissionTimeout.map { $0 > .zero } ?? true, "admissionTimeout must be positive")
            try require(loadTimeout > .zero, "loadTimeout must be positive")
            try require(maximumEventsPerRequest >= 1, "maximumEventsPerRequest must be at least 1")
            try require(observationBufferLimit >= 1, "observationBufferLimit must be at least 1")
        }
    }

    public let configuration: Configuration
    public let store: LlamaModelStore?
    public var limits: Limits { configuration.limits }

    let native: NativeEngine
    let state: RuntimeState
    let admission: Admission
    private let catalogMutex = AsyncMutex()
    private let pump: Task<Void, Never>

    /// Requests waiting natively for a load, beyond the admitted generations:
    /// explicit loads, one per instance. A safety bound, not a second queue.
    static let nativeLoadMargin = 64

    /// Creates a runtime and its native engine; nothing is loaded. The models
    /// of `store` are in the catalog.
    public init(configuration: Configuration = Configuration(), store: LlamaModelStore? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        self.store = store
        let state = RuntimeState(configuration: configuration)
        let admission = Admission(capacity: configuration.limits.maximumActiveGenerations,
                                  waitingCapacity: configuration.limits.maximumWaitingRequests,
                                  timeout: configuration.limits.admissionTimeout,
                                  onChange: { [weak state] in state?.publish() })
        state.admission = admission
        for artifact in try store?.artifacts() ?? [] {
            state.add(artifact)
        }
        let catalog: [String: Any] = [
            "max_loaded": configuration.limits.maximumResidentModels,
            "autoload": true,
            "wait_timeout_ms": Int64(configuration.loadTimeout.components.seconds * 1000 +
                                     configuration.loadTimeout.components.attoseconds / 1_000_000_000_000_000),
            "max_waiting": configuration.limits.maximumActiveGenerations + Self.nativeLoadMargin,
            "max_subscriber_events": 256,
            "models": [Any](),
        ]
        let native = try NativeEngine.createCatalog(configuration: try JSONSerialization.data(withJSONObject: catalog),
                                                    workers: NativeWorkers())
        let subscription = try native.subscribe()
        self.native = native
        self.state = state
        self.admission = admission
        // Engine state events feed the snapshots. The pump ends when the engine
        // stops (its subscription terminates) and does not keep it alive.
        pump = Task.detached { [weak native, state] in
            while true {
                let event = await subscription.next(timeout: .seconds(1))
                if event.isTerminal { break }
                if event.kind == .payload {
                    state.applyNative(event.data, catalog: { try? native?.catalog() })
                }
            }
        }
    }

    deinit {
        state.hub.close()
        // The native engine stops and joins on a worker when released.
    }

    // MARK: - Observation

    /// Current state.
    public func snapshot() -> LlamaRuntimeSnapshot {
        state.snapshot()
    }

    /// The current snapshot, then every change. A subscriber that falls more
    /// than `bufferLimit` updates behind receives one `resync` instead.
    public func updates(bufferLimit: Int? = nil) -> LlamaRuntimeUpdates {
        state.hub.subscribe(limit: bufferLimit ?? configuration.observationBufferLimit) { state.snapshot() }
    }

    // MARK: - Catalog

    /// Adds model files that the application owns (bundled resources, files it
    /// manages itself). Removing such a model never deletes its files.
    public func register(_ artifact: LlamaModelArtifact) throws {
        guard artifact.id.isValid else {
            throw LlamaEngineError.invalidConfiguration("invalid model identifier '\(artifact.id)'")
        }
        guard !artifact.weights.isEmpty else {
            throw LlamaEngineError.invalidModelFile("\(artifact.id) has no weight file")
        }
        for file in artifact.weights + [artifact.projector].compactMap({ $0 }) {
            _ = try LlamaModelStore.checkGGUF(file)
        }
        var unmanaged = artifact
        unmanaged.isManaged = false
        try state.insert(unmanaged)
    }

    /// Copies a model into the store, then adds it to the catalog. Other
    /// models keep running; the source files are left untouched.
    public func importModel(_ request: LlamaModelImport) async throws -> LlamaModelArtifact {
        guard let store else {
            throw LlamaEngineError.invalidConfiguration("the runtime has no model store")
        }
        try state.reserveImport(request.id)
        defer { state.endImport(request.id) }
        let cancelled = CancellationFlag()
        let artifact = try await withTaskCancellationHandler {
            try await native.workers.run { try store.importModel(request) { cancelled.isSet } }
        } onCancel: {
            cancelled.set()
        }
        state.add(artifact)
        state.publish()
        return artifact
    }

    /// Removes a model from the catalog: closes its admissions, ends its
    /// generations and waiting requests, frees its instances, then deletes its
    /// managed copy (never the files an import was made from, nor registered
    /// files). Other models keep running.
    public func removeModel(_ id: LlamaModelID) async throws {
        while let unload = state.unloadTask(of: id) {
            await unload.value
        }
        let artifact = try state.beginRemoval(id)
        state.publish()
        let reason = LlamaEngineError.modelUnavailable(id, reason: "removed")
        admission.close(model: id, error: reason)
        state.closeGenerations(of: id, reason: reason)
        await state.submissionsEnded(id)
        do {
            try await catalogMutex.run {
                let removed = state.removeInstances(of: id)
                let event = await native.updateCatalog(models: state.nativeModels())
                guard event.kind == .success else {
                    state.restoreInstances(removed)
                    throw event.error
                }
            }
            if artifact.isManaged, let store {
                try await native.workers.run { try store.remove(id) }
            }
        } catch {
            state.endRemoval(id, removed: false)
            state.publish()
            throw error
        }
        state.endRemoval(id, removed: true)
        refresh()
    }

    // MARK: - Lifecycle

    /// Loads an instance explicitly (optional: generations load on demand).
    /// Concurrent loads of the same instance share one native load. Cancelling
    /// the caller stops its wait; a load the engine already started is not
    /// interrupted (unload does that).
    public func load(_ id: LlamaModelID, profile: LlamaLoadProfile) async throws {
        let key = try state.instanceKey(id, profile)
        let entry = try await ensureInstance(key)
        let load = state.sharedLoad(entry) {
            SharedLoad(model: id) { [native] in try await native.load(model: entry) } onDone: { [state] load in
                state.endLoad(entry, load)
            }
        }
        try await load.wait()
        refresh()
    }

    /// Explicit unload of every instance of a model: closes its admissions,
    /// ends its generations (`unloaded`) and waiting requests, and returns
    /// once the engine freed the resources. Admissions reopen afterwards: a
    /// new request loads the model again. Concurrent calls share one unload.
    public func unload(_ id: LlamaModelID) async throws {
        let task = try state.beginUnload(id) {
            Task { [self] in
                let reason = LlamaEngineError.unloaded(id)
                admission.close(model: id, error: reason)
                state.closeGenerations(of: id, reason: reason)
                await state.submissionsEnded(id)
                for entry in state.entries(of: id) {
                    _ = await native.unload(model: entry) // model_not_loaded when not resident
                }
                refresh()
                state.endUnload(id)
                state.publish()
            }
        }
        state.publish()
        await task.value
    }

    /// Stops the engine: every request ends (`stopped`), subscriptions finish.
    public func shutdown() async {
        state.hub.close()
        await native.stop()
    }

    // MARK: - Generations

    /// Submits a generation after admission. `body` is an engine request (JSON
    /// object) without `model`; the runtime selects the instance.
    package func generate(_ operation: String = "chat", model id: LlamaModelID, profile: LlamaLoadProfile, body: Data,
                          attachments: [NativeAttachment] = []) async throws -> LlamaGeneration {
        let key = try state.instanceKey(id, profile)
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LlamaEngineError.invalidConfiguration("a generation body is a JSON object")
        }
        let permit = try await admission.acquire(model: id)
        let generation = LlamaGeneration(model: id, profile: profile, permit: permit) { [weak state] id in
            state?.unregister(id)
        }
        try state.register(generation) // fails if the model closed during the wait
        do {
            object["model"] = try await ensureInstance(key)
            try Task.checkCancellation()
            let body = try JSONSerialization.data(withJSONObject: object)
            // An unload or removal starting now waits for this submission, then
            // ends what it started: a closed generation never loads its model again.
            try state.beginSubmit(id)
            defer { state.endSubmit(id) }
            try generation.attach(try await native.submit(operation, body: body, attachments: attachments))
        } catch {
            generation.close(error as? LlamaEngineError ?? .unloaded(id))
            throw error
        }
        return generation
    }

    /// Adds the instance to the native catalog if needed. Entries of other
    /// instances are unchanged, so the engine keeps them loaded.
    private func ensureInstance(_ key: InstanceKey) async throws -> String {
        let entry = key.entryID
        try await catalogMutex.run {
            _ = try state.instanceKey(key.model, key.profile) // not closed meanwhile
            guard state.addInstance(key) else { return }
            let event = await native.updateCatalog(models: state.nativeModels())
            guard event.kind == .success else {
                state.dropInstance(entry)
                throw event.error
            }
            state.publish()
        }
        return entry
    }

    /// Reads the engine catalog now, so that a snapshot taken when a load or
    /// unload returns already shows its outcome (the pump may lag behind).
    private func refresh() {
        state.applyNative(Data(#"{"type":"refresh"}"#.utf8), catalog: { try? native.catalog() })
    }

    /// The engine catalog (JSON), for diagnostics and tests.
    package func nativeCatalog() throws -> Data {
        try native.catalog()
    }
}

// MARK: - Shared state

/// Catalog, availability, instances and generations of a runtime, guarded by
/// one lock so that snapshots and admission checks see a consistent state.
final class RuntimeState: @unchecked Sendable {
    private struct NativeInstance: Hashable {
        var state: LlamaRuntimeSnapshot.InstanceState = .unloaded
        var active = 0
        var waiting = 0
    }

    private struct WeakGeneration {
        weak var generation: LlamaGeneration?
    }

    let configuration: LlamaRuntime.Configuration
    let hub = UpdateHub()
    weak var admission: Admission? // set once, before use

    private let lock = NSLock()
    // guarded by lock
    private var artifacts: [LlamaModelID: LlamaModelArtifact] = [:]
    private var availability: [LlamaModelID: LlamaRuntimeSnapshot.Availability] = [:]
    private var instances: [InstanceKey] = []
    private var native: [String: NativeInstance] = [:]
    private var generations: [UUID: WeakGeneration] = [:]
    private var loads: [String: SharedLoad] = [:]
    private var unloads: [LlamaModelID: Task<Void, Never>] = [:]
    private var imports: Set<LlamaModelID> = []
    private var submitting: [LlamaModelID: Int] = [:]
    private var submissionWaiters: [LlamaModelID: [CheckedContinuation<Void, Never>]] = [:]

    init(configuration: LlamaRuntime.Configuration) {
        self.configuration = configuration
    }

    // MARK: Snapshots

    func snapshot() -> LlamaRuntimeSnapshot {
        let counts = admission?.counts ?? AdmissionCounts()
        return lock.withLock {
            let models = artifacts.values.sorted { $0.id < $1.id }.map { artifact in
                LlamaRuntimeSnapshot.Model(
                    artifact: artifact,
                    availability: availability[artifact.id] ?? .available,
                    instances: instances.filter { $0.model == artifact.id }.map { key in
                        let instance = native[key.entryID] ?? NativeInstance()
                        return LlamaRuntimeSnapshot.Instance(profile: key.profile, state: instance.state,
                                                             activeRequests: instance.active,
                                                             loadingRequests: instance.waiting)
                    },
                    waitingRequests: counts.waitingByModel[artifact.id] ?? 0)
            }
            return LlamaRuntimeSnapshot(models: models, admission: .init(
                activeGenerations: counts.active, waitingRequests: counts.waiting,
                maximumActiveGenerations: configuration.limits.maximumActiveGenerations,
                maximumWaitingRequests: configuration.limits.maximumWaitingRequests))
        }
    }

    func publish() {
        hub.publish { snapshot() }
    }

    /// Applies a subscription event of the engine. Status changes re-read the
    /// engine catalog, which is authoritative; progress events update one entry.
    func applyNative(_ data: Data, catalog: () -> Data?) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if event["type"] as? String == "progress" {
            guard let model = event["model"] as? String else { return }
            let progress = (event["progress"] as? [String: Any])?["value"] as? Double
            lock.withLock {
                if case .loading = native[model]?.state {
                    native[model]?.state = .loading(progress: progress)
                }
            }
        } else {
            let models = catalog().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                ?? event["models"] as? [[String: Any]]
            guard let models else { return }
            lock.withLock {
                var updated: [String: NativeInstance] = [:]
                for model in models {
                    guard let id = model["id"] as? String else { continue }
                    var instance = NativeInstance()
                    switch model["status"] as? String {
                    case "loading":
                        let previous = native[id].flatMap { if case .loading(let p) = $0.state { return p } else { return nil } }
                        instance.state = .loading(progress: ((model["progress"] as? [String: Any])?["value"] as? Double) ?? previous)
                    case "loaded": instance.state = .loaded
                    case "sleeping": instance.state = .sleeping
                    case "unloading": instance.state = .unloading
                    case "failed": instance.state = .failed(model["error"] as? String ?? "")
                    default: instance.state = .unloaded
                    }
                    instance.active = model["active"] as? Int ?? 0
                    instance.waiting = model["waiting"] as? Int ?? 0
                    updated[id] = instance
                }
                native = updated
            }
        }
        publish()
    }

    // MARK: Catalog

    func add(_ artifact: LlamaModelArtifact) {
        lock.withLock { artifacts[artifact.id] = artifact }
    }

    func insert(_ artifact: LlamaModelArtifact) throws {
        try lock.withLock {
            guard artifacts[artifact.id] == nil, !imports.contains(artifact.id) else {
                throw LlamaEngineError.modelExists(artifact.id)
            }
            artifacts[artifact.id] = artifact
        }
        publish()
    }

    func reserveImport(_ id: LlamaModelID) throws {
        try lock.withLock {
            guard artifacts[id] == nil, !imports.contains(id) else {
                throw LlamaEngineError.modelExists(id)
            }
            imports.insert(id)
        }
    }

    func endImport(_ id: LlamaModelID) {
        _ = lock.withLock { imports.remove(id) }
    }

    /// The instance of an available model; validates the profile against it.
    func instanceKey(_ id: LlamaModelID, _ profile: LlamaLoadProfile) throws -> InstanceKey {
        let artifact = try lock.withLock { try available(id) }
        guard profile.contextSize >= 1 else {
            throw LlamaEngineError.invalidConfiguration("contextSize must be positive")
        }
        if profile.usesProjector && artifact.projector == nil {
            throw LlamaEngineError.invalidConfiguration("\(id) has no projector")
        }
        return InstanceKey(model: id, profile: profile)
    }

    private func available(_ id: LlamaModelID) throws -> LlamaModelArtifact { // lock held
        guard let artifact = artifacts[id] else { throw LlamaEngineError.modelNotFound(id) }
        switch availability[id] ?? .available {
        case .available: return artifact
        case .unloading: throw LlamaEngineError.modelUnavailable(id, reason: "being unloaded")
        case .removing: throw LlamaEngineError.modelUnavailable(id, reason: "being removed")
        }
    }

    /// Adds an instance; false if it is already in the catalog.
    func addInstance(_ key: InstanceKey) -> Bool {
        lock.withLock {
            guard !instances.contains(key) else { return false }
            instances.append(key)
            return true
        }
    }

    func dropInstance(_ entry: String) {
        lock.withLock { instances.removeAll { $0.entryID == entry } }
    }

    func removeInstances(of id: LlamaModelID) -> [InstanceKey] {
        lock.withLock {
            let removed = instances.filter { $0.model == id }
            instances.removeAll { $0.model == id }
            return removed
        }
    }

    func restoreInstances(_ keys: [InstanceKey]) {
        lock.withLock {
            for key in keys where !instances.contains(key) {
                instances.append(key)
            }
        }
    }

    func entries(of id: LlamaModelID) -> [String] {
        lock.withLock { instances.filter { $0.model == id }.map(\.entryID) }
    }

    /// The models of the native catalog, one per instance (llama_bridge.h).
    /// Deterministic: an unchanged instance keeps the same settings, so the
    /// engine keeps it loaded across catalog updates.
    func nativeModels() -> Data {
        let limits = configuration.limits
        let models: [[String: Any]] = lock.withLock {
            instances.compactMap { key in
                guard let artifact = artifacts[key.model] else { return nil }
                let profile = key.profile
                let slots = limits.maximumActiveGenerations
                var settings: [String: Any] = [
                    "model_path": artifact.weights[0].path,
                    "context_size": profile.contextSize * slots, // split evenly between the slots
                    "parallel": slots,
                    "gpu_layers": profile.compute.gpuLayers,
                    "max_events": configuration.maximumEventsPerRequest,
                    "options": profile.engineOptions.merging(["flash-attn": profile.compute.flashAttention.rawValue]) { _, typed in typed },
                ]
                if profile.usesProjector, let projector = artifact.projector {
                    settings["mmproj_path"] = projector.path
                }
                if let threads = profile.compute.threads { settings["threads"] = threads }
                if let batch = profile.compute.batchSize { settings["batch_size"] = batch }
                if let micro = profile.compute.microBatchSize { settings["micro_batch_size"] = micro }
                if let template = profile.chatTemplate { settings["chat_template"] = template }
                return ["id": key.entryID, "settings": settings]
            }
        }
        return try! JSONSerialization.data(withJSONObject: models, options: [.sortedKeys])
    }

    // MARK: Generations

    func register(_ generation: LlamaGeneration) throws {
        try lock.withLock {
            _ = try available(generation.model)
            generations[generation.id] = WeakGeneration(generation: generation)
        }
    }

    /// A native submission for an available model is in progress.
    func beginSubmit(_ id: LlamaModelID) throws {
        try lock.withLock {
            _ = try available(id)
            submitting[id, default: 0] += 1
        }
    }

    func endSubmit(_ id: LlamaModelID) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            submitting[id, default: 1] -= 1
            guard submitting[id] == 0 else { return [] }
            submitting[id] = nil
            return submissionWaiters.removeValue(forKey: id) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns once no submission for the model is in progress. Called after
    /// its admissions closed, so no new one starts.
    func submissionsEnded(_ id: LlamaModelID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle: Bool = lock.withLock {
                if submitting[id] == nil { return true }
                submissionWaiters[id, default: []].append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    func unregister(_ id: UUID) {
        _ = lock.withLock { generations.removeValue(forKey: id) }
    }

    /// Ends the generations of a model; each returns its permit once.
    func closeGenerations(of id: LlamaModelID, reason: LlamaEngineError) {
        let closing = lock.withLock { generations.values.compactMap(\.generation).filter { $0.model == id } }
        for generation in closing {
            generation.close(reason)
        }
    }

    // MARK: Loads, unloads, removals

    func sharedLoad(_ entry: String, make: () -> SharedLoad) -> SharedLoad {
        let (load, created): (SharedLoad, Bool) = lock.withLock {
            if let load = loads[entry] { return (load, false) }
            let load = make()
            loads[entry] = load
            return (load, true)
        }
        if created {
            load.start()
        }
        return load
    }

    func endLoad(_ entry: String, _ load: SharedLoad) {
        lock.withLock {
            if loads[entry] === load {
                loads[entry] = nil
            }
        }
    }

    func beginUnload(_ id: LlamaModelID, _ make: () -> Task<Void, Never>) throws -> Task<Void, Never> {
        try lock.withLock {
            guard artifacts[id] != nil else { throw LlamaEngineError.modelNotFound(id) }
            if let task = unloads[id] { return task }
            if availability[id] == .removing {
                throw LlamaEngineError.modelUnavailable(id, reason: "being removed")
            }
            availability[id] = .unloading
            let task = make()
            unloads[id] = task
            return task
        }
    }

    func endUnload(_ id: LlamaModelID) {
        lock.withLock {
            unloads[id] = nil
            if availability[id] == .unloading {
                availability[id] = nil
            }
        }
    }

    func unloadTask(of id: LlamaModelID) -> Task<Void, Never>? {
        lock.withLock { unloads[id] }
    }

    func beginRemoval(_ id: LlamaModelID) throws -> LlamaModelArtifact {
        try lock.withLock {
            let artifact = try available(id)
            availability[id] = .removing
            return artifact
        }
    }

    func endRemoval(_ id: LlamaModelID, removed: Bool) {
        lock.withLock {
            availability[id] = nil
            if removed {
                artifacts[id] = nil
            }
        }
    }
}

// MARK: - Helpers

/// One native load shared by every caller of `LlamaRuntime.load` for the same
/// instance. A caller that cancels only stops waiting; when the last one
/// leaves before the end, the native load request is cancelled, which removes
/// a load still waiting in the engine but does not interrupt a started one.
final class SharedLoad: @unchecked Sendable {
    private let model: LlamaModelID
    private let submit: @Sendable () async throws -> NativeRequest
    private let onDone: @Sendable (SharedLoad) -> Void

    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    private let lock = NSLock()
    // guarded by lock
    private var result: Result<Void, any Error>?
    private var waiters: [ObjectIdentifier: Waiter] = [:]
    private var request: NativeRequest?
    private var abandoned = false

    init(model: LlamaModelID, submit: @escaping @Sendable () async throws -> NativeRequest,
         onDone: @escaping @Sendable (SharedLoad) -> Void) {
        self.model = model
        self.submit = submit
        self.onDone = onDone
    }

    func start() {
        Task {
            do {
                let request = try await submit()
                let abandoned = lock.withLock {
                    self.request = request
                    return self.abandoned
                }
                if abandoned { request.cancel() }
                while true {
                    let event = try await request.next()
                    switch event.kind {
                    case .payload, .timeout:
                        continue
                    case .success:
                        complete(.success(()))
                    case .cancelled where event.category == "unloaded":
                        complete(.failure(LlamaEngineError.unloaded(model)))
                    case .cancelled, .error:
                        complete(.failure(event.error))
                    }
                    return
                }
            } catch {
                complete(.failure(error))
            }
        }
    }

    private func complete(_ outcome: Result<Void, any Error>) {
        let waiting: [Waiter] = lock.withLock {
            result = outcome
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        onDone(self)
        for waiter in waiting {
            waiter.continuation?.resume(with: outcome)
        }
    }

    func wait() async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Result<Void, any Error>? = lock.withLock {
                    if waiter.cancelled { return .failure(CancellationError()) }
                    if let result { return result }
                    waiter.continuation = continuation
                    waiters[ObjectIdentifier(waiter)] = waiter
                    return nil
                }
                if let ready {
                    continuation.resume(with: ready)
                }
            }
        } onCancel: {
            let (continuation, request, last): (CheckedContinuation<Void, any Error>?, NativeRequest?, Bool) = lock.withLock {
                waiter.cancelled = true
                guard waiters.removeValue(forKey: ObjectIdentifier(waiter)) != nil else { return (nil, nil, false) }
                let last = waiters.isEmpty && result == nil
                if last { abandoned = true }
                return (waiter.continuation, self.request, last)
            }
            if last {
                onDone(self) // later callers start a new load
                request?.cancel()
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// Serializes the native catalog updates of a runtime (FIFO, not reentrant).
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false // guarded by lock
    private var waiters: [CheckedContinuation<Void, Never>] = [] // guarded by lock

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired: Bool = lock.withLock {
                if !locked {
                    locked = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
        defer {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                if waiters.isEmpty {
                    locked = false
                    return nil
                }
                return waiters.removeFirst()
            }
            next?.resume()
        }
        return try await body()
    }
}

/// A cancellation request for blocking work running on a worker.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
