import SwiftUI
import UniformTypeIdentifiers
import LlamaEngine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    @State private var showImagePicker: Bool = false
    @State private var showAudioPicker: Bool = false

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

                lifecycleButtons
            }

            HStack {
                TextField("mmproj .gguf (optionnel, pour vision/audio)", text: $vm.mmprojPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.engineState != .unloaded)
            }

            if vm.engineState == .ready, vm.capabilities.hasAnyCapability {
                capabilitiesLabel
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

                    Toggle("Enable tools (get_current_time, calculator)", isOn: $vm.enableTools)
                        .disabled(vm.engineState == .ready && !vm.capabilities.supportsToolCalls)
                        .help(vm.engineState == .ready && !vm.capabilities.supportsToolCalls
                              ? "The loaded chat template does not advertise tool-call support."
                              : "Expose the local tools to the model as OpenAI-style functions.")
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
        VStack(spacing: 6) {
            if !vm.pendingAttachments.isEmpty {
                pendingAttachmentsStrip
            }

            HStack(alignment: .bottom, spacing: 8) {
                if vm.capabilities.supportsVision {
                    Button {
                        showImagePicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    .help("Joindre une image")
                    .disabled(vm.engineState != .ready)
                    .fileImporter(
                        isPresented: $showImagePicker,
                        allowedContentTypes: [.image],
                        allowsMultipleSelection: true
                    ) { result in
                        if case .success(let urls) = result {
                            for u in urls { vm.addImage(fromURL: u) }
                        }
                    }
                }
                if vm.capabilities.supportsAudio {
                    Button {
                        showAudioPicker = true
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .help("Joindre un fichier audio (.wav / .mp3)")
                    .disabled(vm.engineState != .ready)
                    .fileImporter(
                        isPresented: $showAudioPicker,
                        allowedContentTypes: audioTypes,
                        allowsMultipleSelection: true
                    ) { result in
                        if case .success(let urls) = result {
                            for u in urls { vm.addAudio(fromURL: u) }
                        }
                    }
                }

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
                    .disabled(vm.messages.isEmpty && vm.pendingAttachments.isEmpty)
            }
        }
        .padding(12)
    }

    private var pendingAttachmentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingAttachments) { att in
                    PendingAttachmentChip(attachment: att) {
                        vm.removePendingAttachment(att.id)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioTypes: [UTType] {
        [UTType.wav, UTType.mp3].compactMap { $0 }
    }

    /// Boutons Pause / Resume pour tester le cycle de pause du moteur.
    /// Le bouton Pause reste actif pendant `.loading` et `.resuming` :
    /// l'appel préempte activement le chargement (initial ou resume) via le
    /// progress-callback côté llama.cpp — c'est le scénario iOS → background.
    @ViewBuilder private var lifecycleButtons: some View {
        switch vm.engineState {
        case .pausing:
            Button("Pausing…") { }
                .buttonStyle(.bordered)
                .disabled(true)
        case .ready, .loading, .resuming:
            if vm.canPause {
                Button("Pause", action: vm.pauseModel)
                    .buttonStyle(.bordered)
                    .help(pauseHelp(for: vm.engineState))
            }
        case .paused:
            if vm.canResume {
                Button("Resume", action: vm.resumeModel)
                    .buttonStyle(.borderedProminent)
                    .help("Recharge le modèle avec les mêmes paramètres.")
            }
        case .unloaded, .unloading:
            EmptyView()
        }
    }

    private func pauseHelp(for state: EngineState) -> String {
        switch state {
        case .loading:  return "Interrompt le chargement en cours et passe en pause."
        case .resuming: return "Interrompt la reprise en cours et reste en pause."
        default:        return "Libère le contexte, conserve la config pour resume()."
        }
    }

    private var capabilitiesLabel: some View {
        HStack(spacing: 6) {
            Text("Capabilities:")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if vm.capabilities.supportsVision {
                CapabilityBadge(text: "vision", icon: "eye", tint: .blue)
            }
            if vm.capabilities.supportsAudio {
                CapabilityBadge(text: "audio", icon: "waveform", tint: .blue)
            }
            if vm.capabilities.supportsToolCalls {
                CapabilityBadge(text: "tool calls", icon: "wrench.and.screwdriver", tint: .orange)
            }
            if vm.capabilities.supportsReasoning {
                CapabilityBadge(text: "reasoning", icon: "brain", tint: .purple)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    /// Un simple entier qui change à chaque token reçu (content ou reasoning),
    /// utilisé pour déclencher le scroll automatique sans dépendre d'un unique
    /// champ.
    private var scrollSignal: Int {
        guard let last = vm.messages.last else { return 0 }
        let toolArgs = last.toolCalls.reduce(0) { $0 &+ $1.arguments.count &+ $1.name.count }
        return last.content.count &+ last.reasoning.count &+ toolArgs &+ vm.messages.count
    }

    private var stateColor: Color {
        switch vm.engineState {
        case .unloaded:  return .gray
        case .loading:   return .orange
        case .ready:     return .green
        case .paused:    return .blue
        case .unloading: return .orange
        case .pausing:   return .blue
        case .resuming:  return .orange
        }
    }
}

private struct CapabilityBadge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

private extension EngineCapabilities {
    /// True as soon as the loaded model advertises any kind of capability
    /// (multimodal, tool-calls, or reasoning). Used to decide whether to
    /// render the capability badge strip.
    var hasAnyCapability: Bool {
        supportsVision || supportsAudio || supportsToolCalls || supportsReasoning
    }
}

private struct PendingAttachmentChip: View {
    let attachment: ChatMessage.Attachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isImage, let img = AttachmentRenderer.image(from: attachment.data) {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: attachment.isAudio ? "waveform.circle.fill" : "paperclip")
                            .font(.title3)
                        Text(attachment.filename)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 80, height: 56)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }
}

/// Décodage d'octets d'image vers une `SwiftUI.Image` (cross-platform).
enum AttachmentRenderer {
    static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded: Bool = true

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if message.role == .tool {
                    toolResultView
                } else {
                    if message.hasAttachments {
                        attachmentsView
                    }
                    if message.hasReasoning {
                        reasoningView
                    }
                    if message.hasToolCalls {
                        toolCallsView
                    }
                    if shouldShowContentBubble {
                        Text(placeholderOrContent)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(background)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
        .onChange(of: message.content) { newValue in
            if !newValue.isEmpty { reasoningExpanded = false }
        }
    }

    // MARK: - Sub-views

    private var attachmentsView: some View {
        let images  = message.attachments.filter { $0.isImage }
        let audios  = message.attachments.filter { $0.isAudio }
        return VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(images) { att in
                        if let img = AttachmentRenderer.image(from: att.data) {
                            img
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: 180, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            ForEach(audios) { att in
                HStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text(att.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if case .audio(let fmt) = att.kind {
                        Text(fmt.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
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

    private var toolCallsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.toolCalls) { call in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call \(call.name)")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(call.arguments.isEmpty ? "{}" : call.arguments)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var toolResultView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Result of \(message.toolName ?? "tool")")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Derived

    private var roleLabel: String {
        switch message.role {
        case .tool: return "TOOL · \(message.toolName ?? "")"
        default:    return message.role.rawValue.uppercased()
        }
    }

    /// N'affiche une bulle "content" que si on a réellement du texte OU aucun
    /// autre bloc (reasoning/tool_calls/attachments) capable de remplir la zone.
    private var shouldShowContentBubble: Bool {
        if !message.content.isEmpty { return true }
        if message.isStreaming
            && !message.hasReasoning
            && !message.hasToolCalls
            && !message.hasAttachments { return true }
        return false
    }

    private var placeholderOrContent: String {
        if message.content.isEmpty && message.isStreaming { return "…" }
        return message.content
    }

    private var background: Color {
        switch message.role {
        case .user:      return Color.accentColor.opacity(0.18)
        case .assistant: return Color.gray.opacity(0.15)
        case .system:    return Color.yellow.opacity(0.15)
        case .tool:      return Color.green.opacity(0.08)
        }
    }
}

extension ChatViewModel {
    /// Convenience flag used by the view layer (avoids leaking the private Task).
    var isStreaming: Bool {
        messages.last?.isStreaming == true
    }
}
