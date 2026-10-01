import FoundationModels
import LlamaEngine
import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            IndicatorsView(conversation: conversation)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if conversation.turns.isEmpty {
                            EmptyConversation(conversation: conversation)
                        }
                        ForEach(conversation.turns) { turn in
                            TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id, conversation: conversation)
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: conversation.turns.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: conversation.turns.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            ComposerView(conversation: conversation)
        }
        .navigationTitle(conversation.modelName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct EmptyConversation: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New conversation with \(conversation.modelName)").font(.headline)
            if let profile = conversation.profile {
                Text(profile.summary).font(.caption).foregroundStyle(.secondary)
            }
            Text("Try: “What is (17+25)*3?”, “How much are 3 pens and a mug?”, a photo, "
                + "or the City guide mode for a structured answer.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }
}

/// The two indicators: what the request is doing (with the prompt progress)
/// and the context occupancy. Separate, and never derived from `session.usage`.
struct IndicatorsView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let state = conversation.monitorState
        let gauge = ContextGauge(state)
        let activity = ActivityStatus(monitor: state, model: model.installed(conversation.modelID),
                                      profile: conversation.profile, admission: model.runtimeSnapshot?.admission)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request").font(.caption2).foregroundStyle(.secondary)
                if let activity {
                    Text(activity.label).font(.caption)
                    if let progress = activity.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView(value: 0).opacity(activity.phase == .generating ? 0 : 0.3)
                    }
                } else {
                    Text("Idle").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: 0).opacity(0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("indicator.request")

            VStack(alignment: .leading, spacing: 4) {
                Text("Context").font(.caption2).foregroundStyle(.secondary)
                Text(gauge.label).font(.caption.monospacedDigit())
                    .foregroundStyle(gauge.value == .unavailable ? .secondary : .primary)
                ProgressView(value: gauge.fraction ?? 0)
                    .tint(gauge.isLive ? .accentColor : .gray)
                    .opacity(gauge.fraction == nil ? 0.3 : 1)
                Text(gauge.caption).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("indicator.context")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .opacity(conversation.hasMonitor ? 1 : 0.4)
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let conversation: Conversation
    @State private var text = ""
    @State private var kind = TurnRequest.Kind.chat
    @State private var images: [PromptImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFilePicker = false
    @State private var imageError: String?

    var body: some View {
        @Bindable var model = model
        let available = model.isAvailable(conversation)
        let refusal = conversation.refusal(images: images)
        VStack(alignment: .leading, spacing: 8) {
            if !available {
                Label("\(conversation.modelName) is no longer installed: this conversation is read-only.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Mode", selection: $kind) {
                    ForEach(TurnRequest.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("composer.mode")
                Spacer()
                capabilityToggle("Tools", systemImage: "wrench.and.screwdriver", isOn: $model.settings.tools,
                                 capability: .toolCalling)
                capabilityToggle("Reasoning", systemImage: "brain", isOn: $model.settings.reasoning,
                                 capability: .reasoning)
            }
            .font(.caption)
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { image in
                            image.image.resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 6))
                                .overlay(alignment: .topTrailing) {
                                    Button("Remove", systemImage: "xmark.circle.fill") {
                                        images.removeAll { $0.id == image.id }
                                    }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                        }
                    }
                }
            }
            if let message = refusal ?? imageError {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom) {
                Menu {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Label("Photo library", systemImage: "photo")
                    }
                    Button("Choose a file…", systemImage: "folder") { showsFilePicker = true }
                } label: {
                    Label("Add an image", systemImage: "photo.badge.plus")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(conversation.capabilities.contains(.vision) ? "Add an image" : conversation.visionUnavailableReason)

                TextField(kind == .cityGuide ? "A city, e.g. Lyon" : "Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .accessibilityIdentifier("composer.text")

                if conversation.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { conversation.cancel() }
                        .labelStyle(.iconOnly).font(.title2)
                        .accessibilityIdentifier("composer.stop")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly).font(.title2)
                        .disabled(!available || refusal != nil || text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("composer.send")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addImages(items) }
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                imageError = nil
                for url in urls {
                    do { images.append(try await PromptImage.load(url)) } catch { imageError = error.localizedDescription }
                }
            }
        }
    }

    private func capabilityToggle(_ title: String, systemImage: String, isOn: Binding<Bool>,
                                  capability: LanguageModelCapabilities.Capability) -> some View {
        let supported = conversation.capabilities.contains(capability)
        return Toggle(isOn: supported ? isOn : .constant(false)) {
            Label(title, systemImage: systemImage)
                .labelStyle(isCompact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        }
        .toggleStyle(.button)
        .fixedSize()
        .disabled(!supported)
        .help(supported ? title : "\(title): not qualified for \(conversation.modelName)")
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private func addImages(_ items: [PhotosPickerItem]) async {
        imageError = nil
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PromptImage.Unreadable() }
                images.append(try await PromptImage.decode(data))
            } catch {
                imageError = error.localizedDescription
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !conversation.isResponding, model.isAvailable(conversation),
              conversation.refusal(images: images) == nil else { return }
        let request = conversation.makeRequest(kind: kind, text: trimmed, images: images, settings: model.settings)
        if conversation.send(request) {
            text = ""
            images = []
        }
    }
}

/// A type-erased label style, to choose one at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
