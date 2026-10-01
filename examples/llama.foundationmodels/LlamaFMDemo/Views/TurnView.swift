import FoundationModels
import SwiftUI

struct TurnView: View {
    let turn: Turn
    let isLast: Bool
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PromptBubble(request: turn.request)
            ForEach(turn.itemsBeforeAnswer) { item in
                ItemView(item: item)
            }
            answer
            footer
        }
    }

    @ViewBuilder private var answer: some View {
        switch turn.request.kind {
        case .chat:
            if !turn.text.isEmpty {
                Text(turn.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("turn.answer")
            }
        case .cityGuide:
            if let guide = turn.guide {
                CityGuideCard(guide: guide)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch turn.status {
        case .running:
            ProgressView().controlSize(.small)
        case .complete:
            if let usage = turn.usage {
                Text("Response: \(usage.input) prompt tokens (\(usage.cachedInput) cached) · \(usage.output) generated"
                    + (usage.reasoning > 0 ? " (\(usage.reasoning) reasoning)" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .interrupted(let interruption):
            VStack(alignment: .leading, spacing: 6) {
                ErrorText(error: ErrorPresentation(message: interruption.message, detail: interruption.detail))
                Text("Interrupted: what is shown above is not part of the conversation.")
                    .font(.caption2).foregroundStyle(.secondary)
                if isLast, conversation.canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { conversation.retry() }
                        .accessibilityIdentifier("turn.retry")
                }
            }
            .padding(8)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }
}

struct PromptBubble: View {
    let request: TurnRequest

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if request.kind == .cityGuide {
                Text("City guide · @Generable").font(.caption2).foregroundStyle(.secondary)
            }
            if !request.images.isEmpty {
                HStack {
                    ForEach(request.images) { image in
                        image.image.resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 160)
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }
            }
            Text(request.text)
                .padding(10)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ItemView: View {
    let item: Turn.Item

    var body: some View {
        switch item {
        case .reasoning(_, let text):
            DisclosureGroup {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Reasoning", systemImage: "brain").font(.caption)
            }
            .padding(8)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
        case .toolCalls(_, let calls):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(calls) { call in
                    Label {
                        Text("\(call.tool)(\(call.arguments))").font(.caption.monospaced())
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                }
            }
            .accessibilityIdentifier("turn.toolCall")
        case .toolOutput(_, let tool, let text):
            Label {
                Text("\(tool) → \(text)").font(.caption.monospaced())
            } icon: {
                Image(systemName: "arrow.turn.down.right")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("turn.toolOutput")
        case .response(_, let text):
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct CityGuideCard: View {
    let guide: CityGuide.PartiallyGenerated

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(guide.name ?? "…").font(.title3.bold())
                if let country = guide.country { Text(country).foregroundStyle(.secondary) }
            }
            if let population = guide.population {
                Label("\(population.formatted()) inhabitants", systemImage: "person.3")
            }
            if let landmarks = guide.landmarks, !landmarks.isEmpty {
                Label {
                    Text(landmarks.joined(separator: " · "))
                } icon: {
                    Image(systemName: "building.columns")
                }
            }
            if let summary = guide.summary { Text(summary).italic() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("turn.cityGuide")
    }
}
