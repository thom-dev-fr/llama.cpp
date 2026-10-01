import LlamaEngine
import SwiftUI

/// Catalog downloads, installed models (load, unload, delete) and import.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsImport = false
    @State private var pendingRemoval: LlamaRuntimeSnapshot.Model?

    var body: some View {
        Form {
            Section {
                ForEach(model.catalog?.models ?? []) { entry in
                    CatalogEntryRow(entry: entry)
                }
            } header: {
                Text("Catalog")
            } footer: {
                Text("Models pinned to a source revision, verified by size and SHA-256. "
                    + "Downloads continue in the background.")
            }

            Section {
                if model.installedModels.isEmpty {
                    Text("No model on this device").foregroundStyle(.secondary)
                }
                ForEach(model.installedModels, id: \.id) { installed in
                    InstalledModelRow(installed: installed, onRemove: { pendingRemoval = installed })
                }
                Button("Import a GGUF file…", systemImage: "square.and.arrow.down") { showsImport = true }
            } header: {
                Text("On this device")
            } footer: {
                if let admission = model.runtimeSnapshot?.admission {
                    Text("Generations \(admission.activeGenerations)/\(admission.maximumActiveGenerations) · "
                        + "waiting \(admission.waitingRequests)/\(admission.maximumWaitingRequests) · "
                        + "one resident model")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model library")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showsImport) {
            NavigationStack { ImportModelView() }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 380)
                #endif
        }
        .confirmationDialog("Delete \(pendingRemoval?.artifact.displayName ?? "")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { installed in
            Button("Delete", role: .destructive) { model.remove(installed.id) }
        } message: { installed in
            Text(installed.artifact.isManaged
                ? "Its generations stop and the copy in the app is deleted. The file it was imported from is kept."
                : "Its generations stop and it leaves the catalog. Its files are not deleted.")
        }
    }
}

struct CatalogEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: LlamaModelCatalog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.displayName).font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: entry.totalSize, countStyle: .file)) · "
                        + "\(entry.license.identifier) · \(entry.source.repository)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            CapabilityList(capabilities: entry.qualifiedCapabilities)
            if let download = model.download(entry.id) {
                DownloadProgress(download: download)
            }
            ActionError(action: .download(entry.id))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var actions: some View {
        if model.installed(entry.id) != nil {
            Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.green).labelStyle(.titleAndIcon)
        } else if let download = model.download(entry.id) {
            let busy = model.running.contains(.download(entry.id))
            HStack {
                switch download.state {
                case .downloading:
                    Button("Pause", systemImage: "pause.circle") { model.pauseDownload(entry.id) }.disabled(busy)
                case .paused, .interrupted, .failed:
                    Button("Resume", systemImage: "arrow.clockwise.circle") { model.resumeDownload(entry.id) }
                case .verifying, .installing:
                    ProgressView().controlSize(.small)
                }
                if download.state != .installing {
                    Button("Cancel", systemImage: "xmark.circle", role: .destructive) { model.cancelDownload(entry.id) }
                        .disabled(busy)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } else {
            Button("Download", systemImage: "arrow.down.circle") { model.startDownload(entry) }
                .buttonStyle(.borderless)
        }
    }
}

struct DownloadProgress: View {
    let download: LlamaModelDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: download.fractionCompleted)
            Text(status).font(.caption).foregroundStyle(isProblem ? .orange : .secondary)
        }
    }

    private var bytes: String {
        "\(ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)) of "
            + ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file)
    }

    private var isProblem: Bool {
        switch download.state {
        case .interrupted, .failed: true
        default: false
        }
    }

    private var status: String {
        switch download.state {
        case .downloading: "Downloading · \(bytes)"
        case .paused: "Paused · \(bytes)"
        case .interrupted(let issue): "Interrupted, can resume: \(issue.text)"
        case .verifying: "Verifying the files"
        case .installing: "Installing"
        case .failed(let issue): "Failed: \(issue.text)"
        }
    }
}

extension LlamaDownloadIssue {
    var text: String {
        switch self {
        case let .network(file, _, message): "\(file): \(message)"
        case let .httpStatus(file, status): "\(file): HTTP \(status)"
        case let .sizeMismatch(file, expected, actual): "\(file): \(actual) bytes instead of \(expected)"
        case let .digestMismatch(file, _, _): "\(file): the content does not match the catalog digest"
        case let .insufficientSpace(required, available):
            "not enough space (\(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) needed, "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free)"
        case let .transferLost(file, reason): "\(file): \(reason)"
        case let .storage(reason): reason
        }
    }
}

struct InstalledModelRow: View {
    @Environment(AppModel.self) private var model
    let installed: LlamaRuntimeSnapshot.Model
    let onRemove: () -> Void

    var body: some View {
        let id = installed.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(installed.artifact.displayName).font(.headline)
                        if model.settings.selectedModel == id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Use in a new conversation", systemImage: "bubble.left") { model.selectModel(id) }
                    Button("Load", systemImage: "arrow.up.circle") { model.load(installed) }
                        .disabled(model.running.contains(.load(id)) || isLoaded)
                    Button("Unload", systemImage: "arrow.down.circle") { model.unload(id) }
                        .disabled(model.running.contains(.unload(id)) || installed.instances.allSatisfy { $0.state == .unloaded })
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive, action: onRemove)
                        .disabled(model.running.contains(.remove(id)))
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            CapabilityList(capabilities: installed.artifact.catalogEntry?.qualifiedCapabilities ?? [],
                           emptyText: "Imported: guided generation only (capabilities not qualified)")
            InstanceStatus(installed: installed, profile: model.profile(for: installed))
            ActionError(action: .load(id))
            ActionError(action: .unload(id))
            ActionError(action: .remove(id))
        }
        .padding(.vertical, 2)
    }

    private var isLoaded: Bool {
        installed.instances.contains { $0.profile == model.profile(for: installed) && $0.state == .loaded }
    }

    private var details: String {
        var parts = [installed.artifact.catalogEntry == nil ? "Imported" : "Catalog"]
        if installed.artifact.weights.count > 1 { parts.append("\(installed.artifact.weights.count) shards") }
        if installed.artifact.projector != nil { parts.append("projector") }
        if installed.availability != .available { parts.append(installed.availability.rawValue) }
        return parts.joined(separator: " · ")
    }
}

/// The state of the instances of a model, the current profile's first.
struct InstanceStatus: View {
    let installed: LlamaRuntimeSnapshot.Model
    let profile: LlamaLoadProfile

    var body: some View {
        let instances = installed.instances.filter { $0.state != .unloaded || $0.profile == profile }
        if instances.isEmpty {
            Text("Not loaded · \(profile.summary)").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(instances.enumerated()), id: \.offset) { _, instance in
            HStack(spacing: 6) {
                switch instance.state {
                case .loading(let progress):
                    if let progress {
                        ProgressView(value: progress).frame(maxWidth: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Loading")
                case .loaded: Image(systemName: "memorychip").foregroundStyle(.green); Text("Loaded")
                case .sleeping: Text("Sleeping")
                case .unloading: ProgressView().controlSize(.small); Text("Unloading")
                case .unloaded: Text("Not loaded")
                case .failed(let message): Image(systemName: "exclamationmark.triangle").foregroundStyle(.red); Text("Failed: \(message)")
                }
                Text("· \(instance.profile.summary)").foregroundStyle(.secondary)
                if instance.activeRequests > 0 { Text("· \(instance.activeRequests) running") }
            }
            .font(.caption)
        }
    }
}

struct CapabilityList: View {
    let capabilities: [LlamaModelCatalog.Capability]
    var emptyText = "No qualified capability"

    var body: some View {
        HStack(spacing: 6) {
            if capabilities.isEmpty {
                Text(emptyText).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(capabilities, id: \.self) { capability in
                Text(capability.title)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
        }
    }
}

extension LlamaModelCatalog.Capability {
    var title: String {
        switch self {
        case .guidedGeneration: "Structured output"
        case .toolCalling: "Tools"
        case .reasoning: "Reasoning"
        case .vision: "Images"
        }
    }
}

extension LlamaLoadProfile {
    var summary: String {
        let compute: String = switch compute.offload {
        case .none: "CPU"
        case .automatic: "auto"
        case .all: "GPU"
        case .layers(let count): "\(count) GPU layers"
        }
        return "\(contextSize.formatted()) tokens · \(compute)" + (usesProjector ? " · projector" : "")
    }
}

/// The error of one action, where the action was asked.
struct ActionError: View {
    @Environment(AppModel.self) private var model
    let action: AppModel.Action

    var body: some View {
        if let error = model.errors[action] {
            ErrorText(error: error)
        }
    }
}

struct ErrorText: View {
    let error: ErrorPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if let detail = error.detail, !detail.isEmpty {
                DisclosureGroup("Details") {
                    Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .font(.callout)
    }
}
