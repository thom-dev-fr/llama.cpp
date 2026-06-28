import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ChatViewModel
    @State private var showImagePicker: Bool = false
    @State private var showAudioPicker: Bool = false

    var body: some View {
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
                    .help("Attach an image")
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
                    .help("Attach an audio file (.wav / .mp3)")
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
                ForEach(vm.pendingAttachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        vm.removePendingAttachment(attachment.id)
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
}
