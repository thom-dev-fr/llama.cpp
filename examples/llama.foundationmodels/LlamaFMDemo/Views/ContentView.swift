import LlamaEngine
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showsLibrary = false
    @State private var showsSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedConversationID) {
                if !model.setupErrors.isEmpty {
                    Section {
                        ForEach(model.setupErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                        }
                    }
                }
                Section("Model") {
                    ModelPicker()
                    Button("Model library", systemImage: "square.stack.3d.down.right") { showsLibrary = true }
                }
                Section("Conversations") {
                    if model.conversations.isEmpty {
                        Text("No conversation yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                    }
                }
            }
            .navigationTitle("llama.cpp FM")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #endif
            .toolbar {
                ToolbarItem {
                    Button("New conversation", systemImage: "square.and.pencil") { model.startConversation() }
                        .disabled(model.selectedModel == nil)
                }
                ToolbarItem {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
            }
        } detail: {
            if let conversation = model.currentConversation {
                ChatView(conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView {
                    Label("No model", systemImage: "cpu")
                } description: {
                    Text("Download a model of the catalog or import a GGUF file.")
                } actions: {
                    Button("Open the model library") { showsLibrary = true }
                }
            }
        }
        .sheet(isPresented: $showsLibrary) {
            NavigationStack { LibraryView() }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 520)
                #endif
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack { SettingsView() }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
        }
    }
}

/// Chooses the model of new conversations.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.installedModels.isEmpty {
            Text("No model installed").foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: Binding(
                get: { model.settings.selectedModel },
                set: { id in if let id { model.selectModel(id) } })) {
                ForEach(model.installedModels, id: \.id) { installed in
                    Text(installed.artifact.displayName).tag(Optional(installed.id))
                }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title).lineLimit(1)
            HStack(spacing: 4) {
                Text(conversation.modelName)
                Text("·")
                Text(conversation.startedAt, style: .time)
                if conversation.isResponding {
                    Image(systemName: "ellipsis.bubble").symbolEffect(.pulse)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
