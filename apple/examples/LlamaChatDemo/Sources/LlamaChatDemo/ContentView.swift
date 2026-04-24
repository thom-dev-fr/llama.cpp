import SwiftUI
import LlamaEngine

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            settingsPanel
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text("LlamaChatDemo")
                .font(.headline)
            Text("— \(vm.engineState.description)")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            if let err = vm.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Chemin vers le modèle .gguf", text: $vm.modelPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.engineState != .unloaded)

                if vm.canLoad {
                    Button("Load", action: vm.loadModel)
                        .buttonStyle(.borderedProminent)
                } else if vm.canUnload {
                    Button("Unload", role: .destructive, action: vm.unloadModel)
                        .buttonStyle(.bordered)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                }
            }

            DisclosureGroup("Paramètres") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("System prompt", text: $vm.systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)

                    HStack {
                        Text("Context")
                        Stepper(value: $vm.contextSize, in: 512...32768, step: 512) {
                            Text("\(vm.contextSize)")
                                .monospacedDigit()
                                .frame(width: 64, alignment: .leading)
                        }
                        Spacer()
                        Text("GPU layers")
                        Stepper(value: $vm.gpuLayers, in: -1...999) {
                            Text("\(vm.gpuLayers)")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .disabled(vm.engineState != .unloaded)

                    HStack {
                        Text("Temperature")
                        Slider(value: $vm.temperature, in: 0...2)
                        Text(String(format: "%.2f", vm.temperature))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Flash attention", isOn: $vm.flashAttention)
                        .disabled(vm.engineState != .unloaded)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if vm.messages.isEmpty {
                        Text("Charge un modèle puis pose une question.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(vm.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: scrollSignal) { _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $vm.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(vm.send)
                .disabled(vm.engineState != .ready)

            if vm.isStreaming {
                Button("Stop", role: .destructive, action: vm.cancelStream)
                    .buttonStyle(.bordered)
            } else {
                Button("Send", action: vm.send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canSend)
            }

            Button("Clear", action: vm.resetConversation)
                .buttonStyle(.bordered)
                .disabled(vm.messages.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Helpers

    /// Un simple entier qui change à chaque token reçu (content ou reasoning),
    /// utilisé pour déclencher le scroll automatique sans dépendre d'un unique
    /// champ.
    private var scrollSignal: Int {
        guard let last = vm.messages.last else { return 0 }
        return last.content.count &+ last.reasoning.count
    }

    private var stateColor: Color {
        switch vm.engineState {
        case .unloaded:  return .gray
        case .loading:   return .orange
        case .ready:     return .green
        case .sleeping:  return .blue
        case .unloading: return .orange
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded: Bool = true

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if message.hasReasoning {
                    reasoningView
                }

                if !message.content.isEmpty || !message.hasReasoning {
                    Text(placeholderOrContent)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(background)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
        .onChange(of: message.content) { newValue in
            // Replie automatiquement le bloc « thinking » dès que la réponse
            // finale commence à arriver, pour laisser la lecture au contenu.
            if !newValue.isEmpty { reasoningExpanded = false }
        }
    }

    private var placeholderOrContent: String {
        if message.content.isEmpty && message.isStreaming {
            return message.hasReasoning ? "…" : "…"
        }
        return message.content
    }

    private var reasoningView: some View {
        DisclosureGroup(isExpanded: $reasoningExpanded) {
            Text(message.reasoning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text(message.isStreaming && message.content.isEmpty ? "Thinking…" : "Thought")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var background: Color {
        switch message.role {
        case .user:      return Color.accentColor.opacity(0.18)
        case .assistant: return Color.gray.opacity(0.15)
        case .system:    return Color.yellow.opacity(0.15)
        }
    }
}

extension ChatViewModel {
    /// Convenience flag used by the view layer (avoids leaking the private Task).
    var isStreaming: Bool {
        messages.last?.isStreaming == true
    }
}
