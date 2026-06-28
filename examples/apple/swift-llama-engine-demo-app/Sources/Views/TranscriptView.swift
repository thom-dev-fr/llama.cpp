import SwiftUI

struct TranscriptView: View {
    let vm: ChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if vm.messages.isEmpty {
                        Text("Load a model, then ask a question.")
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
            .onChange(of: scrollSignal) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var scrollSignal: Int {
        guard let last = vm.messages.last else { return 0 }
        let toolArgs = last.toolCalls.reduce(0) { $0 &+ $1.arguments.count &+ $1.name.count }
        return last.content.count &+ last.reasoning.count &+ toolArgs &+ vm.messages.count
    }
}
