import SwiftUI
import UniformTypeIdentifiers

/// Copies a local GGUF file, and optionally its projector, into the app.
struct ImportModelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var weights: URL?
    @State private var projector: URL?
    @State private var isPicking = false
    @State private var pickedField = Field.weights

    private enum Field { case weights, projector }

    var body: some View {
        let importing = model.running.contains(.importModel)
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(weights?.deletingPathExtension().lastPathComponent ?? "My model"))
                fileRow("Weights (GGUF)", url: weights, field: .weights)
                fileRow("Projector (optional)", url: projector, field: .projector)
            } footer: {
                Text("The files are copied into the app; the originals are never modified or deleted. "
                    + "For a split model, choose the first shard: the others must be next to it. "
                    + "An imported model gets structured output only: tools, reasoning and images "
                    + "need a qualified catalog model.")
            }
            if let error = model.errors[.importModel] {
                Section { ErrorText(error: error) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import a model")
        .disabled(importing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(importing)
            }
            ToolbarItem(placement: .confirmationAction) {
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import") {
                        guard let weights else { return }
                        Task {
                            if await model.importModel(name: name, weights: weights, projector: projector) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(weights == nil)
                }
            }
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            switch pickedField {
            case .weights: weights = url
            case .projector: projector = url
            }
        }
        .interactiveDismissDisabled(importing)
    }

    private func fileRow(_ title: String, url: URL?, field: Field) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(url?.lastPathComponent ?? "None").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if url != nil, field == .projector {
                Button("Remove", systemImage: "xmark.circle") { projector = nil }.labelStyle(.iconOnly)
            }
            Button("Choose…") {
                pickedField = field
                isPicking = true
            }
        }
        .buttonStyle(.borderless)
    }
}
