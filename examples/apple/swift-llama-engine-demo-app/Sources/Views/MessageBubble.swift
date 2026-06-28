import SwiftUI

struct MessageBubble: View {
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
        .onChange(of: message.content) { newValue, _ in
            if !newValue.isEmpty { reasoningExpanded = false }
        }
    }

    // MARK: - Sub-views

    private var attachmentsView: some View {
        let images = message.attachments.filter { $0.isImage }
        let audios = message.attachments.filter { $0.isAudio }
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
                Text(message.isStreaming && message.content.isEmpty ? "Thinking..." : "Thought")
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
        case .tool: return "TOOL - \(message.toolName ?? "")"
        default:    return message.role.rawValue.uppercased()
        }
    }

    private var shouldShowContentBubble: Bool {
        if !message.content.isEmpty { return true }
        if message.isStreaming
            && !message.hasReasoning
            && !message.hasToolCalls
            && !message.hasAttachments { return true }
        return false
    }

    private var placeholderOrContent: String {
        if message.content.isEmpty && message.isStreaming { return "..." }
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
