import SwiftUI
import LlamaEngine

struct HeaderView: View {
    let vm: ChatViewModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text("LlamaChatDemo")
                .font(.headline)
            Text("- \(vm.engineState.description)")
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

    private var stateColor: Color {
        switch vm.engineState {
        case .unloaded: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .paused: return .blue
        case .unloading: return .orange
        case .pausing: return .blue
        case .resuming: return .orange
        }
    }
}
